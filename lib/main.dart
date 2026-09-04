import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:intl/intl.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path_provider/path_provider.dart';

// Public HTTPS API hostname. The backend private IP/port is not used by the mobile client.
const apiBase = 'https://apis.suvidhapos.in/api/V1';
const supportUrl = 'https://wa.me/918271718844';
const appTitle = 'SuvidhaPos Live Sale';
const refreshSeconds = 60;

/// Returns the authoritative Gross Sale value used by Dashboard calculations.
///
/// This helper is intentionally public so invariant tests can validate the
/// same Gross Sale rules used by the UI. It accepts either one normalized row,
/// a list/iterable of rows, or a response map containing summary rows. Gross is
/// never silently replaced with Net Sale.
num dashboardGrossValue(dynamic source) {
  Iterable<Map<String, dynamic>> rows;
  if (source is Map) {
    final map = Map<String, dynamic>.from(source);
    final direct = summaryRowsFromApi(map);
    rows = direct.isNotEmpty ? direct : <Map<String, dynamic>>[map];
  } else if (source is Iterable) {
    rows = source
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row));
  } else {
    return 0;
  }

  num sumAliases(List<Map<String, dynamic>> input, List<String> names) =>
      input.fold<num>(0, (sum, row) => sum + number(field(row, names)));

  // Dashboard/Sale is the only source of truth for Dashboard Gross Sale.
  // Never derive Gross from Avg Revenue, Order Count, Net Sale, bill rows,
  // or any other fallback when the API does not provide it.
  return sumAliases(rows.toList(), [
    'grossTotal', 'grossSale', 'gross_sale', 'grossAmount', 'gross_amount',
    'totalGross', 'gross', 'gross_total', 'total_gross', 'grossSales',
    'gross_sales',
  ]);
}

void main() => runApp(const SuvidhaPosLiveSaleApp());

class SuvidhaPosLiveSaleApp extends StatelessWidget {
  const SuvidhaPosLiveSaleApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF7C4DFF),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: appTitle,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF080B25),
        colorScheme: scheme,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF080B25),
          surfaceTintColor: Colors.transparent,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF111633),
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF111633),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFF252B55)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFF252B55)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFF7C4DFF), width: 1.5),
          ),
        ),
      ),
      home: const AuthGate(),
    );
  }
}

class _ApiKeyRejected implements Exception {}

class _HttpStatusException implements Exception {
  final int statusCode;
  final String message;
  const _HttpStatusException(this.statusCode, this.message);
}

class ApiService {
  final String key;
  const ApiService(this.key);

  static final http.Client _client = _buildClient();

  static http.Client _buildClient() {
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12)
      ..idleTimeout = const Duration(seconds: 20)
      ..maxConnectionsPerHost = 6;
    return IOClient(httpClient);
  }

  /// Sends a request with a short, controlled retry policy.
  ///
  /// IMPORTANT: authentication failures (400/401/403/422) are never retried.
  /// Retrying those responses can make a valid key look intermittently invalid
  /// and can also trigger gateway rate limits. Only transport/transient server
  /// failures are retried.
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, String> fields, {
    bool allowEmptyPayload = false,
    bool freshConnection = false,
    bool legacyLoginHeaders = false,
    bool includeApiKeyFields = true,
    Duration requestTimeout = const Duration(seconds: 20),
  }) async {
    final cleanKey = key.trim();
    if (cleanKey.isEmpty) {
      throw Exception('API key is missing. Please activate this device once.');
    }

    Object? lastError;
    const maxAttempts = 3;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      http.Client? requestClient;
      try {
        requestClient = freshConnection ? _buildClient() : _client;

        final request = http.MultipartRequest(
          'POST',
          Uri.parse('$apiBase$path'),
        );
        request.headers.addAll({
          'accept': 'application/json, text/plain, */*',
          // Login/key changes always use a new TCP/TLS connection and no-cache
          // semantics. This avoids stale gateway/session state after Logout or
          // Change API Key.
          'connection': freshConnection ? 'close' : 'keep-alive',
          if (freshConnection) 'cache-control': 'no-cache, no-store',
          if (freshConnection) 'pragma': 'no-cache',
          if (freshConnection)
            'X-Request-ID': DateTime.now().microsecondsSinceEpoch.toString(),
          // DashboardLogin is deployed behind multiple POS gateway versions.
          // Keep all accepted API-key header aliases for compatibility.
          'Keys': cleanKey,
          if (!legacyLoginHeaders) 'Key': cleanKey,
          if (!legacyLoginHeaders) 'X-API-Key': cleanKey,
        });
        request.fields.addAll({
          ...fields,
          if (includeApiKeyFields && !legacyLoginHeaders) 'Keys': cleanKey,
          if (includeApiKeyFields && !legacyLoginHeaders) 'key': cleanKey,
          if (includeApiKeyFields && !legacyLoginHeaders) 'APIKey': cleanKey,
        });

        final streamed = await requestClient
            .send(request)
            .timeout(requestTimeout);
        final response = await http.Response.fromStream(streamed)
            .timeout(requestTimeout);
        final decoded = _decodeJson(response.body);

        if (_looksLikeInvalidKey(response.body, decoded)) {
          throw _ApiKeyRejected();
        }

        if (response.statusCode < 200 || response.statusCode >= 300) {
          final message = _serverMessage(decoded);
          throw _HttpStatusException(
            response.statusCode,
            message.isEmpty
                ? 'Server error (${response.statusCode})'
                : message,
          );
        }

        if (decoded is! Map) {
          throw http.ClientException('Empty server response');
        }

        final result = Map<String, dynamic>.from(decoded);
        if (!allowEmptyPayload && _hasNullPayload(result)) {
          throw http.ClientException('POS returned null data');
        }
        return result;
      } catch (e) {
        lastError = e;

        // Never retry a definitive API-key or HTTP authentication failure.
        if (e is _ApiKeyRejected || e is _HttpStatusException) {
          final status = e is _HttpStatusException ? e.statusCode : null;
          final retryableStatus = status == 408 ||
              status == 429 ||
              (status != null && status >= 500);
          if (!retryableStatus) break;
        }

        final retryable = e is TimeoutException ||
            e is SocketException ||
            e is http.ClientException ||
            (e is _HttpStatusException &&
                (e.statusCode == 408 ||
                    e.statusCode == 429 ||
                    e.statusCode >= 500));

        if (!retryable || attempt == maxAttempts - 1) break;

        // 400/401/403/422 never reach this branch. Network/5xx retries use
        // bounded exponential backoff with tiny jitter.
        final backoffMs = 400 * (1 << attempt);
        final jitterMs = (attempt * 113) % 180;
        await Future<void>.delayed(
          Duration(milliseconds: backoffMs + jitterMs),
        );
      } finally {
        if (freshConnection) requestClient?.close();
      }
    }

    if (lastError is _ApiKeyRejected) {
      throw Exception(
        'API key rejected by server. Please check the key in Change API Key.',
      );
    }

    if (lastError is _HttpStatusException) {
      final error = lastError;
      if (error.statusCode == 401 || error.statusCode == 403) {
        final serverText = error.message.toLowerCase();
        if (serverText.contains('api key') || serverText.contains('api-key') ||
            serverText.contains('key rejected') || serverText.contains('invalid key')) {
          throw Exception('API key rejected. Please check the API key.');
        }
        throw Exception('Username or password is incorrect.');
      }
      if (error.statusCode == 400) {
        throw Exception(
          error.message.isNotEmpty
              ? error.message
              : 'Request was not accepted by the server.',
        );
      }
      throw Exception(error.message);
    }

    final message = lastError?.toString() ?? 'Request failed';
    final lower = message.toLowerCase();
    if (lower.contains('socketexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('timed out') ||
        lower.contains('connection') ||
        lower.contains('network')) {
      throw Exception(
        'Network connection failed. Your saved API key was not removed. Please retry.',
      );
    }
    throw Exception(message.replaceFirst('Exception: ', ''));
  }

  dynamic _decodeJson(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  String _serverMessage(dynamic decoded) {
    if (decoded is! Map) return '';
    final map = Map<String, dynamic>.from(decoded);
    return stringValue(
      field(map, const [
        'message',
        'msg',
        'error',
        'detail',
        'description',
      ]),
    ).trim();
  }

  bool _looksLikeInvalidKey(String rawBody, dynamic decoded) {
    final raw = rawBody.toLowerCase();
    final message = _serverMessage(decoded).toLowerCase();
    final text = '$raw $message';
    return text.contains('invalid api key') ||
        text.contains('api key is invalid') ||
        text.contains('api key rejected') ||
        text.contains('api key was rejected') ||
        text.contains('invalid key') ||
        text.contains('key is invalid') ||
        text.contains('key rejected');
  }

  bool _hasNullPayload(Map<String, dynamic> json) {
    if (json.isEmpty) return true;
    for (final key in const ['response', 'data', 'result', 'payload']) {
      if (json.containsKey(key) && json[key] == null) return true;
    }
    return false;
  }

  Future<void> login(String id, String password) async {
    final cleanId = id.trim();
    final cleanPassword = password;
    if (cleanId.isEmpty || cleanPassword.isEmpty) {
      throw Exception('Login ID and password are required.');
    }

    // The POS gateway has existed in multiple compatible versions. A valid
    // API key must work repeatedly after Logout and after changing the key.
    //
    // Login therefore uses a bounded compatibility matrix:
    //   1) fresh connection + full legacy body/header aliases
    //   2) pooled connection + full legacy body/header aliases
    //   3) fresh connection + header-only aliases
    //   4) pooled connection + header-only aliases
    //
    // Only transport/contract failures (400/401/403/key-rejected) enter the
    // compatibility matrix. Credential errors are NOT converted into API-key
    // errors; the final server response is mapped to a friendly reason.
    final attempts = <({
      bool freshConnection,
      bool legacyLoginHeaders,
      bool includeApiKeyFields,
    })>[
      (
        freshConnection: true,
        legacyLoginHeaders: false,
        includeApiKeyFields: true,
      ),
      (
        freshConnection: false,
        legacyLoginHeaders: false,
        includeApiKeyFields: true,
      ),
      (
        freshConnection: true,
        legacyLoginHeaders: true,
        includeApiKeyFields: false,
      ),
      (
        freshConnection: false,
        legacyLoginHeaders: true,
        includeApiKeyFields: false,
      ),
    ];

    Object? lastError;
    Map<String, dynamic>? successful;

    for (final attempt in attempts) {
      try {
        successful = await post(
          '/DashboardLogin',
          {
            'LoginID': cleanId,
            'Password': cleanPassword,
          },
          allowEmptyPayload: true,
          freshConnection: attempt.freshConnection,
          legacyLoginHeaders: attempt.legacyLoginHeaders,
          includeApiKeyFields: attempt.includeApiKeyFields,
          requestTimeout: const Duration(seconds: 30),
        );
        break;
      } catch (e) {
        lastError = e;
        final lower = e.toString().toLowerCase();

        final compatibilityFailure =
            e is _ApiKeyRejected ||
            (e is _HttpStatusException &&
                (e.statusCode == 400 ||
                    e.statusCode == 401 ||
                    e.statusCode == 403)) ||
            lower.contains('api key rejected') ||
            lower.contains('server error (400)') ||
            lower.contains('server error (401)') ||
            lower.contains('server error (403)');

        if (!compatibilityFailure) rethrow;

        // Try the next gateway contract/connection mode. Do not sleep here:
        // these are deterministic contract fallbacks, not network retries.
      }
    }

    if (successful == null) {
      if (lastError is _ApiKeyRejected) {
        throw Exception(
          'API key rejected by server. Please verify the API key in Change API Key.',
        );
      }
      if (lastError is _HttpStatusException) {
        final error = lastError;
        final serverText = error.message.toLowerCase();
        if (serverText.contains('api key') ||
            serverText.contains('api-key') ||
            serverText.contains('key rejected') ||
            serverText.contains('invalid key')) {
          throw Exception(
            'API key rejected by server. Please verify the API key in Change API Key.',
          );
        }
        if (error.statusCode == 400) {
          throw Exception(
            'Login request was not accepted. Please check the Login ID and password.',
          );
        }
        if (error.statusCode == 401 || error.statusCode == 403) {
          throw Exception('Username or password is incorrect.');
        }
      }
      throw Exception(
        lastError?.toString().replaceFirst('Exception: ', '') ??
            'Unable to sign in. Please try again.',
      );
    }

    final json = successful;
    final response = responseMap(json);
    final status = field(response, ['status', 'success', 'isSuccess', 'ok']) ??
        field(json, ['status', 'success', 'isSuccess', 'ok']);
    final message = stringValue(
      field(response, [
            'message',
            'msg',
            'error',
            'reason',
            'errorMessage',
            'error_message',
            'statusMessage'
          ]) ??
          field(json, [
            'message',
            'msg',
            'error',
            'reason',
            'errorMessage',
            'error_message',
            'statusMessage'
          ]),
    ).trim();

    final lower = message.toLowerCase();
    final raw = jsonEncode(json).toLowerCase();
    final combinedText = '$lower $raw';

    if (combinedText.contains('key is invalid') ||
        combinedText.contains('invalid api key') ||
        combinedText.contains('api key rejected') ||
        combinedText.contains('api key was rejected') ||
        combinedText.contains('invalid key')) {
      throw Exception(
        'API key rejected. Please verify the API key in Change API Key.',
      );
    }

    if (status != null && !success(status)) {
      throw Exception(_friendlyLoginReason(json, response, message));
    }

    if (status == null &&
        (combinedText.contains('login failed') ||
            combinedText.contains('invalid credential') ||
            combinedText.contains('wrong password') ||
            combinedText.contains('incorrect password') ||
            combinedText.contains('user not found') ||
            combinedText.contains('user not available') ||
            combinedText.contains('username not found'))) {
      throw Exception(_friendlyLoginReason(json, response, message));
    }
  }

  String _friendlyLoginReason(
    Map<String, dynamic> json,
    Map<String, dynamic> response,
    String serverMessage,
  ) {
    final raw = jsonEncode(json).toLowerCase();
    final text = '$serverMessage $raw'.toLowerCase();

    if (text.contains('user not found') ||
        text.contains('username not found') ||
        text.contains('login id not found') ||
        text.contains('user does not exist') ||
        text.contains('user unavailable') ||
        text.contains('user not available')) {
      return 'User not available. Please check the Login ID.';
    }
    if (text.contains('password incorrect') ||
        text.contains('incorrect password') ||
        text.contains('wrong password') ||
        text.contains('invalid password')) {
      return 'Wrong password. Please check your password.';
    }
    if (text.contains('invalid credential') ||
        text.contains('invalid login') ||
        text.contains('wrong credential') ||
        text.contains('wrong login') ||
        text.contains('authentication failed') ||
        text.contains('auth failed') ||
        text.contains('credentials are not valid')) {
      return 'Username or password is incorrect.';
    }
    if (text.contains('login id') &&
        (text.contains('invalid') ||
            text.contains('incorrect') ||
            text.contains('wrong'))) {
      return 'User not available. Please check the Login ID.';
    }
    if (text.contains('api key') &&
        (text.contains('invalid') || text.contains('reject'))) {
      return 'API key rejected. Please verify the API key in Change API Key.';
    }
    if (serverMessage.trim().isNotEmpty &&
        !serverMessage.toLowerCase().contains('login failed')) {
      return serverMessage.trim();
    }
    return 'Username or password is incorrect.';
  }

  Future<Map<String, dynamic>> dashboard(
    String from,
    String to,
    String ids, {
    bool useOutletFilter = false,
  }) {
    return post('/Dashboard/Sale', {
      'from_date': from,
      'to_date': to,
      // Dashboard/Sale historically worked most reliably with ids=0 for the
      // combined dataset. Live Tables can explicitly opt into outlet-scoped
      // requests; all other dashboard callers keep the legacy aggregate path.
      'ids': useOutletFilter ? (ids.trim().isEmpty ? '0' : ids.trim()) : '0',
    });
  }

  /// Live Tables are backed by the POS LiveTableItem/Sale endpoint.
  /// The endpoint is bill-scoped, so the dashboard endpoint is used only to
  /// discover the current bill/table keys; every Live Tables value/detail is
  /// then read from this endpoint.
  Future<Map<String, dynamic>> liveTable(String outletId, String billNo) {
    return post('/LiveTableItem/Sale', {
      'outlet_id': outletId,
      'bill_no': billNo,
    });
  }
}

Map<String, dynamic> asMap(dynamic value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  return <String, dynamic>{};
}

Map<String, dynamic> responseMap(Map<String, dynamic> json) {
  for (final key in ['response', 'data', 'result', 'payload']) {
    final response = asMap(field(json, [key]));
    if (response.isNotEmpty) return response;
  }
  return json;
}

List<Map<String, dynamic>> asRows(dynamic value) {
  if (value is List) {
    return value
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }
  if (value is Map) {
    return <Map<String, dynamic>>[Map<String, dynamic>.from(value)];
  }
  return <Map<String, dynamic>>[];
}

List<Map<String, dynamic>> rowsFromResponse(
  Map<String, dynamic> response,
  List<String> keys,
  List<String> rowHints,
) {
  for (final key in keys) {
    final value = field(response, [key]);
    final rows = asRows(value);
    if (rows.isNotEmpty) return rows;
  }

  bool looksLikeRow(Map<String, dynamic> row) {
    final lowered = row.keys.map((e) => e.toLowerCase()).toSet();
    return rowHints.any(lowered.contains);
  }

  if (looksLikeRow(response)) return <Map<String, dynamic>>[response];

  final found = <Map<String, dynamic>>[];
  void walk(dynamic value) {
    if (value is List) {
      final rows = value
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (rows.isNotEmpty && rows.any(looksLikeRow)) {
        found.addAll(rows);
        return;
      }
      for (final item in value) {
        if (item is Map || item is List) walk(item);
      }
    } else if (value is Map) {
      for (final item in value.values) {
        if (item is Map || item is List) walk(item);
      }
    }
  }

  walk(response);
  return found;
}

dynamic field(Map<String, dynamic> row, List<String> names,
    [dynamic fallback]) {
  for (final name in names) {
    if (row.containsKey(name) && row[name] != null) return row[name];
  }
  final lower = <String, dynamic>{};
  row.forEach((key, value) => lower[key.toLowerCase()] = value);
  for (final name in names) {
    final value = lower[name.toLowerCase()];
    if (value != null) return value;
  }
  return fallback;
}

String stringValue(dynamic value, [String fallback = '']) =>
    value == null ? fallback : value.toString();

bool success(dynamic value) {
  final text = stringValue(value).trim().toLowerCase();
  return text == '1' || text == 'true' || text == 'yes' || text == 'success';
}

num number(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value;
  final text = value.toString().replaceAll(RegExp(r'[^0-9.\-]'), '');
  return num.tryParse(text) ?? 0;
}

String money(dynamic value) => NumberFormat.currency(
      locale: 'en_IN',
      symbol: '₹',
      decimalDigits: 2,
    ).format(number(value));

String compactMoney(dynamic value) {
  final n = number(value);
  final abs = n.abs();
  if (abs >= 10000000) {
    return '₹${(n / 10000000).toStringAsFixed(2)}Cr';
  }
  if (abs >= 100000) {
    return '₹${(n / 100000).toStringAsFixed(2)}L';
  }
  if (abs >= 1000) {
    return '₹${(n / 1000).toStringAsFixed(1)}K';
  }
  return money(n);
}

String dateText(DateTime value) => DateFormat('dd-MMM-yyyy').format(value);
String apiDate(DateTime value) => DateFormat('yyyy-MM-dd').format(value);

class OfflineStore {
  static Future<Directory> _directory() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory('${root.path}/suvidha_live_sale_cache');
    await dir.create(recursive: true);
    return dir;
  }

  static String _safe(String key) =>
      key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  static Future<void> save(String key, Map<String, dynamic> value) async {
    try {
      final dir = await _directory();
      final file = File('${dir.path}/${_safe(key)}.json');
      final payload = jsonEncode({
        'savedAt': DateTime.now().toIso8601String(),
        'data': value,
      });
      await file.writeAsString(payload, flush: true);
    } catch (_) {
      // Offline cache is best-effort; never affect the live UI.
    }
  }

  static Future<Map<String, dynamic>?> read(String key) async {
    try {
      final dir = await _directory();
      final file = File('${dir.path}/${_safe(key)}.json');
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final data = decoded['data'];
      return data is Map ? Map<String, dynamic>.from(data) : null;
    } catch (_) {
      return null;
    }
  }
}

String normalizedId(dynamic value) {
  final text = stringValue(value).trim();
  if (text.isEmpty) return '';
  final parsed = num.tryParse(text);
  if (parsed != null && parsed == parsed.roundToDouble()) {
    return parsed.toInt().toString();
  }
  return text.toLowerCase();
}

String outletIdOf(Map<String, dynamic> row) => normalizedId(
      field(row, [
        'outletId', 'outletID', 'OutletID', 'outlet_id', 'outletid', 'Outlet_Id',
        'outlet_Id', 'outletID_fk', 'outletIdFk', 'outlet_id_fk',
        'o_Id', 'o_id', 'oID', 'outletCode', 'outlet_code',
        'branchId', 'branch_id', 'branchID', 'branchCode', 'branch_code',
        'outletNo', 'outlet_no', 'id'
      ]),
    );

String outletNameOf(Map<String, dynamic> row) => stringValue(
      field(row, [
        'outletName', 'outlet_name', 'OutletName', 'Outlet_Name',
        'outlet', 'outletDesc', 'outlet_desc', 'branchName', 'branch_name',
        'branch', 'description', 'desc', 'name'
      ]),
      'Outlet',
    ).trim();

bool rowMatchesOutlet(
  Map<String, dynamic> row,
  String outletId, {
  String outletName = '',
}) {
  final wantedId = normalizedId(outletId);
  if (wantedId.isEmpty || wantedId == '0') return true;
  final rowId = outletIdOf(row);
  if (rowId == wantedId) return true;
  final wantedName = outletName.trim().toLowerCase();
  if (wantedName.isEmpty || wantedName == 'all outlets') return false;
  final rowName = outletNameOf(row).trim().toLowerCase();
  return rowName != 'outlet' && rowName == wantedName;
}

String billNoOf(Map<String, dynamic> row) => stringValue(
      field(row, [
        'billNo', 'bill_no', 'bill_nofk', 'billNoFk', 'bill_no_fk',
        'BillNo', 'Bill_No', 'billNumber', 'bill_number',
      ]),
    );

String billAmountOf(Map<String, dynamic> row) => stringValue(
      field(row, [
        'billAmount',
        'bill_amount',
        'grossSale',
        'gross_sale',
        'grossTotal',
        'gross_total',
        'grossAmount',
        'gross_amount',
        'totalGross',
        'total_gross'
      ]),
      '0',
    );

num billItemCountOf(Map<String, dynamic> row) => number(field(row, [
      'itemCount',
      'item_count',
      'Item Count',
      'itemsCount',
      'items_count',
      'itemQty',
      'item_qty',
      'quantity',
      'qty',
      'totalItems',
      'total_items',
      'itemTotal',
      'item_total',
      'count',
    ]));

String itemNameOf(Map<String, dynamic> row) => stringValue(
      field(row, [
        'i_Name', 'item_name', 'itemName', 'Item Name', 'ItemName', 'item_name_fk',
        'i_item_name', 'itemdesc', 'item_desc', 'productName', 'product_name',
        'item', 'product', 'description', 'desc', 'name',
      ]),
      'Item',
    ).trim();

num itemQtyOf(Map<String, dynamic> row) => number(field(row, [
      'qty', 'quantity', 'Qty', 'Quantity', 'qtyValue', 'qty_value',
      'item_qty', 'itemQty', 'i_qty', 'sale_qty', 'sold_qty',
      'item_count', 'itemCount', 'Item Count', 'sold_count', 'soldCount',
      'count', 'Count', 'totalQty', 'total_qty', 'quantity_sold',
      'soldQuantity', 'sold_quantity',
    ]));

num itemAmountOf(Map<String, dynamic> row) => number(field(row, [
      'amount', 'item_amount', 'itemAmount', 'netAmount', 'net_amount',
      'lineAmount', 'line_amount', 'totalAmount', 'total_amount',
      'grossAmount', 'gross_amount', 'saleAmount', 'sale_amount',
      'lineTotal', 'line_total', 'total', 'value',
    ]));

String tableNoOf(Map<String, dynamic> row) => stringValue(
      field(row, [
        'tableNo', 'tableno', 'table_No', 'table_no',
        'TableNo', 'Table_No'
      ]),
      '—',
    );

/// Display the POS table name while retaining the UI label `Table No:`.
/// Example: the POS may expose numeric tableNo=1 and t_Name=WS1; the app
/// must render `Table No: WS1`, not `Table No: 1`.
String tableDisplayNameOf(Map<String, dynamic> row) {
  // The numeric tableNo is only an internal POS identifier. The UI label
  // `Table No:` must display the POS table *name* (e.g. TB1/WS1). Never fall
  // back to the numeric table number because that hides a missing name from
  // the API and produces the wrong value for the user.
  const nameKeys = [
    't_Name', 't_name', 'tName', 'TName', 'T_Name',
    'tableName', 'table_name', 'TableName', 'Table_Name',
    'table_name_fk', 'tableNameFk', 'table_name_fk_value',
    'tableDesc', 'table_desc', 'tableDescription', 'table_description',
    'tableDisplayName', 'table_display_name', 'displayTableName',
    'tableLabel', 'table_label',
  ];

  final direct = stringValue(field(row, nameKeys), '').trim();
  if (direct.isNotEmpty) return direct;

  // Some POS deployments wrap table metadata in a nested object. Preserve
  // the API's original table name without inventing or deriving one.
  const nestedKeys = [
    'table', 'tableInfo', 'table_info', 'tableDetails', 'table_details',
    'tableMaster', 'table_master', 'tableData', 'table_data',
  ];
  for (final key in nestedKeys) {
    final rawNested = field(row, [key]);
    if (rawNested is String && rawNested.trim().isNotEmpty) {
      return rawNested.trim();
    }
    final nested = asMap(rawNested);
    if (nested.isEmpty) continue;
    final name = stringValue(field(nested, nameKeys), '').trim();
    if (name.isNotEmpty) return name;
  }

  // A few POS versions expose the master table name directly as `table`.
  final directTable = field(row, ['table']);
  if (directTable is String && directTable.trim().isNotEmpty) {
    return directTable.trim();
  }

  // IMPORTANT: some POS deployments return the printable table identifier
  // (for example `B1` / `WS1`) in `table_no`/`tableno` itself, while another
  // field in the same response may contain the numeric internal table id.
  // A non-numeric table_no is therefore an ORIGINAL POS table name and must
  // be displayed as-is. We never convert a numeric id such as `1` into a
  // guessed name.
  final rawTableNo = stringValue(
    field(row, [
      'table_no', 'tableNo', 'tableno', 'Table_No', 'TableNo', 'table_no_fk',
      'tableNoFk', 't_no', 'tNo',
    ]),
    '',
  ).trim();
  if (rawTableNo.isNotEmpty &&
      rawTableNo != '—' &&
      rawTableNo != '-' &&
      rawTableNo != '0' &&
      !RegExp(r'^\d+(?:\.0+)?$').hasMatch(rawTableNo)) {
    return rawTableNo;
  }

  // Last chance: inspect arbitrary API keys rather than relying only on a
  // fixed casing. POS installations have used variants such as
  // `TableNameFK`, `tbl_name`, `tNameFk`, etc. Only values whose key clearly
  // identifies a table name are accepted; numeric table ids are never used.
  for (final entry in row.entries) {
    final key = entry.key.toString().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if ((key.contains('tablename') ||
            key == 'tname' ||
            key == 'tblname' ||
            key == 'tablelabel') &&
        entry.value != null) {
      final candidate = entry.value.toString().trim();
      if (candidate.isNotEmpty &&
          candidate != '—' &&
          candidate != '-' &&
          candidate != '0') {
        return candidate;
      }
    }
  }

  return '—';
}

List<Map<String, dynamic>> summaryForResponseOutlet(
  Map<String, dynamic> response,
  String outletId, {
  String outletName = '',
}) {
  final wanted = normalizedId(outletId);
  final responseOutletRows = rowsFromResponse(
    responseMap(response),
    const ['outlets', 'outlet', 'outletSummary', 'outlet_summary', 'outletWise', 'outlet_wise'],
    const ['outletid', 'outlet_id', 'outletname', 'outlet_name', 'grosssale', 'netsale'],
  );
  if (wanted != '0' && wanted.isNotEmpty) {
    final matches = responseOutletRows
        .where((row) => rowMatchesOutlet(row, wanted, outletName: outletName))
        .map(normalizeApiMetricRow)
        .toList();
    if (matches.isNotEmpty) return matches;
  }
  final summaries = summaryRowsFromApi(response)
      .map(normalizeApiMetricRow)
      .toList();
  if (wanted == '0' || wanted.isEmpty) return summaries;
  // A response with a single summary row is considered scoped only when it
  // carries matching outlet context. Never treat an unlabelled combined
  // summary as the selected outlet's data.
  final contextual = summaries
      .where((row) => rowMatchesOutlet(row, wanted, outletName: outletName))
      .toList();
  return contextual;
}

List<Map<String, dynamic>> summaryForOutlet(
  Iterable<Map<String, dynamic>> rows,
  String outletId, {
  String outletName = '',
}) {
  final wanted = normalizedId(outletId);
  if (wanted.isEmpty || wanted == '0') {
    final rowsWithOutlet = rows.where((r) => outletIdOf(r).isNotEmpty).toList();
    return rowsWithOutlet.isNotEmpty ? rowsWithOutlet : rows.toList();
  }

  final idMatches = rows.where((r) => rowMatchesOutlet(r, wanted)).toList();
  if (idMatches.isNotEmpty) return idMatches;

  final nameMatches = rows
      .where((r) => rowMatchesOutlet(r, wanted, outletName: outletName))
      .toList();
  if (nameMatches.isNotEmpty) return nameMatches;

  return const <Map<String, dynamic>>[];
}

Future<void> openSupport() async {
  await launchUrl(Uri.parse(supportUrl), mode: LaunchMode.externalApplication);
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  static const storage = FlutterSecureStorage();
  String? activationKey;
  String? loginId;
  String? password;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final key = (await storage.read(key: 'activationKey'))?.trim();
    final id = (await storage.read(key: 'loginId'))?.trim();
    final pass = await storage.read(key: 'loginPassword');
    // Only Logout clears the stored session. Network/DNS outages never log out.
    if (!mounted) return;
    setState(() {
      activationKey = key;
      loginId = id;
      password = pass;
      loading = false;
    });
  }

  Future<void> _saveKey(String value) async {
    final cleanKey = value.trim();
    if (cleanKey.isEmpty) return;

    // Changing the API key starts a completely fresh authentication state.
    // Do not let credentials from the previous key survive into the new key.
    await storage.write(key: 'activationKey', value: cleanKey);
    await storage.delete(key: 'loginId');
    await storage.delete(key: 'loginPassword');
    if (!mounted) return;
    setState(() {
      activationKey = cleanKey;
      loginId = null;
      password = null;
    });
  }

  Future<void> _saveSession(String id, String pass) async {
    await storage.write(key: 'loginId', value: id);
    await storage.write(key: 'loginPassword', value: pass);
    if (!mounted || activationKey == null) return;
    setState(() {
      loginId = id;
      password = pass;
    });
  }

  Future<void> _logout() async {
    await storage.delete(key: 'loginId');
    await storage.delete(key: 'loginPassword');
    if (!mounted) return;
    setState(() {
      loginId = null;
      password = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (activationKey == null || activationKey!.isEmpty) {
      return ActivationPage(onDone: _saveKey);
    }
    if (loginId == null || password == null) {
      return LoginPage(
        keyValue: activationKey!,
        onDone: _saveSession,
        onChangeKey: () async {
          await storage.delete(key: 'activationKey');
          await storage.delete(key: 'loginId');
          await storage.delete(key: 'loginPassword');
          if (mounted) {
            setState(() {
              activationKey = null;
              loginId = null;
              password = null;
            });
          }
        },
      );
    }
    return DashboardShell(
      keyValue: activationKey!,
      loginId: loginId!,
      onLogout: _logout,
    );
  }
}

class BrandHeader extends StatelessWidget {
  final double logoWidth;
  const BrandHeader({super.key, this.logoWidth = 240});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Image.asset(
        'assets/suvidha_logo.png',
        width: logoWidth,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}

class ActivationPage extends StatefulWidget {
  final Future<void> Function(String) onDone;
  const ActivationPage({super.key, required this.onDone});

  @override
  State<ActivationPage> createState() => _ActivationPageState();
}

class _ActivationPageState extends State<ActivationPage> {
  final controller = TextEditingController();
  bool busy = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> activateKey() async {
    final value = controller.text.trim();
    if (value.isEmpty || busy) return;
    setState(() => busy = true);
    try {
      await widget.onDone(value);
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => _authScaffold(
        title: 'Live Sale',
        subtitle: 'Configure this device once with your Suvidha POS API key.',
        child: Column(
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Activation Key',
                prefixIcon: Icon(Icons.key_outlined),
              ),
              onSubmitted: (_) => activateKey(),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: busy ? null : activateKey,
                icon: const Icon(Icons.verified_outlined),
                label: Text(busy ? 'Saving…' : 'Activate & Continue'),
              ),
            ),
            const SizedBox(height: 6),
            TextButton(
                onPressed: openSupport, child: const Text('Contact Support')),
          ],
        ),
      );
}

class LoginPage extends StatefulWidget {
  final String keyValue;
  final Future<void> Function(String, String) onDone;
  final Future<void> Function() onChangeKey;
  const LoginPage(
      {super.key,
      required this.keyValue,
      required this.onDone,
      required this.onChangeKey});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final userController = TextEditingController();
  final passwordController = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void dispose() {
    userController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> signIn() async {
    final id = userController.text.trim();
    final password = passwordController.text;
    if (id.isEmpty || password.isEmpty || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final api = ApiService(widget.keyValue);
      await api.login(id, password);
      await widget.onDone(id, password);
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => _authScaffold(
        title: 'Live Sale',
        subtitle: 'Sign in once. The session stays active until Logout.',
        child: Column(
          children: [
            TextField(
              controller: userController,
              autofillHints: const <String>[],
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Login ID',
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password',
                prefixIcon: Icon(Icons.lock_outline),
              ),
              onSubmitted: (_) => signIn(),
            ),
            if (error != null) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(error!,
                    style: const TextStyle(color: Colors.redAccent)),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: busy ? null : signIn,
                icon: const Icon(Icons.login),
                label: Text(busy ? 'Signing in…' : 'Sign in'),
              ),
            ),
            const SizedBox(height: 6),
            TextButton(
                onPressed: openSupport, child: const Text('Contact Support')),
            TextButton.icon(
              onPressed: busy ? null : widget.onChangeKey,
              icon: const Icon(Icons.key_rounded, size: 17),
              label: const Text('Change API Key'),
            ),
          ],
        ),
      );
}

Widget _authScaffold({
  required String title,
  required String subtitle,
  required Widget child,
}) {
  return Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 30, 28, 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const BrandHeader(logoWidth: 270),
                    const SizedBox(height: 12),
                    const Center(
                      child: Text(
                        appTitle,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 27, fontWeight: FontWeight.w900),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: Text(
                        subtitle,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                    const SizedBox(height: 26),
                    child,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class DashboardShell extends StatefulWidget {
  final String keyValue;
  final String loginId;
  final Future<void> Function() onLogout;

  const DashboardShell({
    super.key,
    required this.keyValue,
    required this.loginId,
    required this.onLogout,
  });

  @override
  State<DashboardShell> createState() => _DashboardShellState();
}

class _DashboardShellState extends State<DashboardShell> {
  late final ApiService api = ApiService(widget.keyValue);
  int index = 0;
  String selectedOutlet = '0';
  String selectedOutletName = 'All Outlets';
  List<Map<String, dynamic>> availableOutlets = [];
  final ValueNotifier<int> syncSignal = ValueNotifier<int>(0);

  @override
  void dispose() {
    syncSignal.dispose();
    super.dispose();
  }

  Future<void> logout() async {
    await widget.onLogout();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardPage(
        key: const ValueKey('dashboard'),
        api: api,
        loginId: widget.loginId,
        selectedOutlet: selectedOutlet,
        onOutletChanged: (id, name) {
          setState(() {
            selectedOutlet = id;
            selectedOutletName = name;
          });
        },
        onLiveSync: () async {
          syncSignal.value++;
        },
        syncSignal: syncSignal,
        onOutletsChanged: (outlets) {
          if (!mounted) return;
          setState(() {
            availableOutlets = List<Map<String, dynamic>>.from(outlets);
          });
        },
        onLogout: logout,
      ),
      LiveTablesPage(
        key: ValueKey('live-$selectedOutlet'),
        api: api,
        outletId: selectedOutlet,
        outletName: selectedOutletName,
        availableOutlets: availableOutlets,
        syncSignal: syncSignal,
        onLogout: logout,
      ),
      ReportsPage(
        key: ValueKey('reports-$selectedOutlet'),
        api: api,
        outletId: selectedOutlet,
        outletName: selectedOutletName,
      ),
    ];

    return Scaffold(
      body: IndexedStack(index: index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) => setState(() {
          index = value;
        }),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.table_bar_outlined),
            selectedIcon: Icon(Icons.table_bar),
            label: 'Live Tables',
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart),
            label: 'Reports',
          ),
        ],
      ),
    );
  }
}

class DashboardPage extends StatefulWidget {
  final ApiService api;
  final String loginId;
  final String selectedOutlet;
  final void Function(String id, String name) onOutletChanged;
  final void Function(List<Map<String, dynamic>> outlets)? onOutletsChanged;
  final Future<void> Function() onLiveSync;
  final ValueNotifier<int> syncSignal;
  final Future<void> Function() onLogout;

  const DashboardPage({
    super.key,
    required this.api,
    required this.loginId,
    required this.selectedOutlet,
    required this.onOutletChanged,
    this.onOutletsChanged,
    required this.onLiveSync,
    required this.syncSignal,
    required this.onLogout,
  });

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}


List<Map<String, dynamic>> outletRowsFromApi(Map<String, dynamic> response) {
  final direct = field(response, ['outlets', 'outletList', 'outletSummary', 'outletWise', 'outletwise']);
  final rows = asRows(direct);
  if (rows.isNotEmpty) return rows;
  return rowsFromResponse(
    response,
    ['outlets', 'outletList', 'outletSummary', 'outletWise', 'outletwise'],
    ['outlet_id', 'outletid', 'outlet_name', 'outletname', 'gross_sale', 'net_sale'],
  );
}

List<Map<String, dynamic>> summaryRowsFromApi(Map<String, dynamic> response) {
  final raw = field(response, ['saleSummary', 'salesummary', 'salesSummary', 'summary', 'sale']);
  if (raw is Map) {
    return [Map<String, dynamic>.from(raw)];
  }
  final rows = asRows(raw);
  if (rows.isNotEmpty) return rows;
  return rowsFromResponse(
    response,
    ['saleSummary', 'salesummary', 'salesSummary', 'summary', 'sale'],
    ['gross_sale', 'grosssale', 'grosstotal', 'net_sale', 'netsale', 'nettotal'],
  );
}

Map<String, dynamic> normalizeApiMetricRow(Map<String, dynamic> row) {
  final r = Map<String, dynamic>.from(row);
  void copy(String target, List<String> names) {
    final existing = field(r, [target]);
    final v = field(r, names);
    // Some POS responses contain a legacy/derived target field as 0 while the
    // actual value is present under another alias. Prefer a non-zero source
    // value instead of letting a placeholder hide the real metric.
    if (v != null &&
        (existing == null || (number(existing) == 0 && number(v) != 0))) {
      r[target] = v;
    }
  }

  // Normalize only aliases of the same Gross Sale field. No comparison with
  // Net Sale and no mathematical reconstruction is performed.
  copy('grossTotal', [
    'grossTotal', 'gross_total', 'grosstotal', 'gross_sale', 'grossSale',
    'grossAmount', 'gross_amount', 'totalGross', 'gross', 'total_gross',
    'grossSales', 'gross_sales',
  ]);
  copy('netTotal', ['net_sale', 'netSale', 'net_total', 'netTotal', 'netAmount', 'totalNet', 'net', 'total_net']);
  copy('taxTotal', [
    'tax', 'taxes', 'tax_sale', 'taxTotal', 'tax_total',
    'taxAmount', 'tax_amount', 'totalTax', 'total_tax'
  ]);
  copy('discountTotal', [
    'discount', 'discounts', 'discount_sale', 'discountTotal',
    'discount_total', 'discountAmount', 'discount_amount',
    'totalDiscount', 'total_discount'
  ]);
  copy('coverTotal', ['covers', 'cover', 'cover_total', 'coverTotal']);
  copy('orderTotal', [
    'orders', 'order_count', 'orderCount', 'order_total', 'orderTotal',
    'totalOrders', 'total_orders'
  ]);
  copy('avgRevenue', [
    'avgRevenue', 'avg_revenue', 'avgRevenuePerBill',
    'avg_revenue_per_bill', 'averageRevenuePerBill',
    'average_revenue_per_bill', 'avgRevPerBill', 'avg_rev_per_bill'
  ]);
  copy('customerServed', ['customers_served', 'customer_served', 'customerServed']);
  copy('unSatteledAmount', ['pending_amount', 'pendingAmount', 'unsettled_amount', 'unSatteledAmount']);
  copy('unSatteledBill', ['pending_bill', 'pending_bills', 'unsettled_bill', 'unSatteledBill']);
  return r;
}

class _DashboardPageState extends State<DashboardPage> {
  late DateTime from = DateTime.now();
  late DateTime to = DateTime.now();
  Map<String, dynamic> data = {};
  Map<String, dynamic> previousWeekData = {};
  List<Map<String, dynamic>> outletList = [];
  // One authoritative row per outlet for the chart. This is kept separate
  // from the tab/card summary rows, which are intentionally combined in
  // All Outlets mode.
  List<Map<String, dynamic>> outletPerformanceRows = [];
  List<Map<String, dynamic>> apiOutletRows = [];
  Map<String, dynamic> apiCombinedSummary = {};
  bool loading = false;
  Timer? timer;
  final Map<String, Map<String, dynamic>> billDetailsCache = {};
  List<Map<String, dynamic>> directItemRowsCache = [];
  int requestId = 0;
  String loadedOutletId = '0';
  String previousLoadedOutletId = '0';

  @override
  void initState() {
    super.initState();
    _restoreCachedSnapshot().then((_) => load());
    timer =
        Timer.periodic(const Duration(seconds: refreshSeconds), (_) => load());
  }

  String _cacheKey(String outletId) =>
      'dashboard_${apiDate(from)}_${apiDate(to)}_${outletId.isEmpty ? '0' : outletId}';

  Future<void> _restoreCachedSnapshot({String? outletId}) async {
    final id = outletId ?? widget.selectedOutlet;
    final cached = await OfflineStore.read(_cacheKey(id));
    if (!mounted || cached == null) return;
    final response = responseMap(cached);
    if (response.isEmpty) return;
    final liveRows = rowsFromResponse(
      response,
      [
        'liveSale',
        'liveSales',
        'liveTable',
        'liveTables',
        'recentSales',
        'recentSale'
      ],
      ['billno', 'bill_no', 'bill_nofk', 'tableno', 'table_no'],
    );
    final outletRows = rowsFromResponse(
      response,
      ['outletSummary', 'outletsummary', 'outlets', 'outletList'],
      ['outletid', 'outlet_id', 'outletname', 'outlet_name'],
    );
    final summaryRows = rowsFromResponse(
      response,
      ['saleSummary', 'salesummary', 'salesSummary', 'summary', 'sale'],
      ['grosstotal', 'grosssale', 'nettotal', 'netsale', 'ordertotal'],
    );
    setState(() {
      data = response;
      if (outletRows.isNotEmpty)
        outletList = _mergeOutlets(outletList, outletRows);
      if (summaryRows.isNotEmpty)
        outletList = _mergeOutlets(outletList, summaryRows);
      if (liveRows.isNotEmpty) outletList = _mergeOutlets(outletList, liveRows);
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<Map<String, dynamic>> _loadDashboardFor(
    String outletId, {
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    final requestFrom = fromDate ?? from;
    final requestTo = toDate ?? to;
    final id = normalizedId(outletId).isEmpty ? '0' : normalizedId(outletId);
    return responseMap(await widget.api
        .dashboard(
          apiDate(requestFrom),
          apiDate(requestTo),
          id,
          useOutletFilter: id != '0',
        )
        .timeout(const Duration(seconds: 20)));
  }

  List<Map<String, dynamic>> _attachOutletContext(
      Iterable<Map<String, dynamic>> rows, String outletId) {
    final id = normalizedId(outletId);
    if (id.isEmpty || id == '0') return rows;
    var name = 'Outlet';
    for (final outlet in outletList) {
      if (outletIdOf(outlet) == id) {
        name = outletNameOf(outlet);
        break;
      }
    }
    return rows.map((row) {
      final copy = Map<String, dynamic>.from(row);
      if (outletIdOf(copy).isEmpty) {
        copy['outletId'] = id;
        copy['outlet_id'] = id;
      }
      if (outletNameOf(copy) == 'Outlet' && name != 'Outlet') {
        copy['outletName'] = name;
        copy['outlet_name'] = name;
      }
      return copy;
    }).toList();
  }

  Future<void> load({
    String? outletId,
    bool forceAllOutlets = false,
    bool resetOutlet = false,
  }) async {
    final request = ++requestId;
    final requestFrom = DateTime(from.year, from.month, from.day);
    final requestTo = DateTime(to.year, to.month, to.day);
    final selectedId = resetOutlet
        ? '0'
        : (forceAllOutlets
            ? '0'
            : normalizedId(outletId ?? widget.selectedOutlet));
    if (resetOutlet) widget.onOutletChanged('0', 'All Outlets');
    if (mounted) setState(() => loading = true);

    try {
      // Dashboard/Sale is the single source of truth. All Outlets uses the
      // API's combined (ids=0) response; a selected outlet uses the API's
      // outlet-scoped response (ids=<selected>). Never filter an aggregate
      // response and pretend it is the selected outlet's original response.
      final aggregateResponse = await _loadDashboardFor(
        selectedId == '0' ? '0' : selectedId,
        fromDate: requestFrom,
        toDate: requestTo,
      );

      final allOutletRows = outletRowsFromApi(aggregateResponse)
          .map(normalizeApiMetricRow)
          .toList();
      final aggregateSummaryRows = summaryRowsFromApi(aggregateResponse)
          .map(normalizeApiMetricRow)
          .toList();
      final rawSummary = field(aggregateResponse, [
        'summary', 'saleSummary', 'salesummary', 'salesSummary', 'sale',
      ]);
      final combinedSummaryMap = rawSummary is Map
          ? normalizeApiMetricRow(Map<String, dynamic>.from(rawSummary))
          : (aggregateSummaryRows.isNotEmpty
              ? aggregateSummaryRows.first
              : <String, dynamic>{});

      if (allOutletRows.isNotEmpty) {
        apiOutletRows = allOutletRows;
        outletList = _mergeOutlets(outletList, allOutletRows);
      }
      if (aggregateSummaryRows.isNotEmpty) {
        outletList = _mergeOutlets(outletList, aggregateSummaryRows);
      }
      final aggregateLiveRows = rowsFromResponse(
        aggregateResponse,
        ['liveSale', 'liveSales', 'liveTable', 'liveTables', 'recentSales', 'recentSale'],
        ['billno', 'bill_no', 'bill_nofk', 'tableno', 'table_no'],
      );
      if (aggregateLiveRows.isNotEmpty) {
        outletList = _mergeOutlets(outletList, aggregateLiveRows);
      }
      apiCombinedSummary = combinedSummaryMap;
      widget.onOutletsChanged?.call(List<Map<String, dynamic>>.from(outletList));

      if (!mounted || request != requestId) return;

      final combinedSummary = <Map<String, dynamic>>[];
      final combinedLive = <Map<String, dynamic>>[];
      final combinedItems = <Map<String, dynamic>>[];
      final performanceRows = <Map<String, dynamic>>[];

      if (selectedId == '0') {
        // The API's combined summary is authoritative for All Outlets.
        if (combinedSummaryMap.isNotEmpty) {
          combinedSummary.add(combinedSummaryMap);
        } else {
          combinedSummary.addAll(aggregateSummaryRows);
        }

        // Outlet bars come directly from the API's outlet-wise rows. No
        // calculation from bills and no gross/net substitution.
        for (final row in allOutletRows) {
          final id = outletIdOf(row);
          if (id.isEmpty || id == '0') continue;
          performanceRows.add({
            'id': id,
            'name': outletNameOf(row),
            'gross': number(field(row, [
              'grossTotal', 'grossSale', 'gross_sale', 'grossAmount',
              'totalGross', 'gross', 'gross_total', 'total_gross',
            ])),
            'net': number(field(row, [
              'netTotal', 'netSale', 'net_sale', 'netAmount', 'totalNet',
              'net', 'net_total', 'total_net',
            ])),
          });
        }

        combinedLive.addAll(aggregateLiveRows);
        combinedItems.addAll(_itemRowsFromResponse(aggregateResponse));
      } else {
        // This response was requested specifically for the selected outlet.
        // Use its original summary/outlet row directly; do not substitute an
        // aggregate row or derive values from other outlets.
        // For a selected outlet, the request itself is already outlet-scoped.
        // The saleSummary row is the authoritative dashboard record and must
        // drive BOTH the cards and the single outlet bar. Never prefer an
        // outlet-wise/secondary row when the scoped summary is present.
        final selectedSummaryRows = aggregateSummaryRows.isNotEmpty
            ? _attachOutletContext(aggregateSummaryRows, selectedId)
            : _attachOutletContext(
                allOutletRows.where((r) =>
                    outletIdOf(r).isEmpty || normalizedId(outletIdOf(r)) == selectedId),
                selectedId,
              );

        combinedSummary.addAll(selectedSummaryRows);

        // The chart and the Gross/Net cards intentionally share this exact
        // normalized API row. A bar tap therefore cannot show a different
        // Gross Sale than the card below it.
        for (final row in selectedSummaryRows.take(1)) {
          performanceRows.add({
            'id': selectedId,
            'name': outletNameOf(row) == 'Outlet'
                ? selectedOutletNameForDashboard
                : outletNameOf(row),
            'gross': number(field(row, [
              'grossTotal', 'grossSale', 'gross_sale', 'grossAmount',
              'gross_amount', 'totalGross', 'gross', 'gross_total',
              'total_gross', 'grossSales', 'gross_sales',
            ])),
            'net': number(field(row, [
              'netTotal', 'netSale', 'net_sale', 'netAmount', 'net_amount',
              'totalNet', 'net', 'net_total', 'total_net',
            ])),
          });
        }

        combinedLive.addAll(
          aggregateLiveRows.where((r) => rowMatchesOutlet(
                r,
                selectedId,
                outletName: selectedOutletNameForDashboard,
              )),
        );
        combinedItems.addAll(
          _itemRowsFromResponse(aggregateResponse).where((r) => rowMatchesOutlet(
                r,
                selectedId,
                outletName: selectedOutletNameForDashboard,
              )),
        );
      }

      final responseForUi = Map<String, dynamic>.from(aggregateResponse);
      responseForUi['saleSummary'] = combinedSummary;
      responseForUi['liveSale'] = combinedLive;
      responseForUi['items'] = combinedItems;

      Map<String, dynamic> previousResponse = {};
      try {
        final previousFrom = requestFrom.subtract(const Duration(days: 7));
        final previousTo = requestTo.subtract(const Duration(days: 7));
        previousResponse = responseMap(await widget.api.dashboard(
          apiDate(previousFrom),
          apiDate(previousTo),
          selectedId,
          useOutletFilter: selectedId != '0',
        ).timeout(const Duration(seconds: 20)));
        previousLoadedOutletId = selectedId;
      } catch (_) {
        previousResponse = {};
      }

      if (!mounted || request != requestId) return;
      loadedOutletId = selectedId;
      setState(() {
        data = responseForUi;
        previousWeekData = previousResponse;
        directItemRowsCache = combinedItems;
        outletPerformanceRows = performanceRows;
      });

      await OfflineStore.save(
        'dashboard_${apiDate(requestFrom)}_${apiDate(requestTo)}_$selectedId',
        responseForUi,
      );
    } catch (_) {
      if (mounted && data.isEmpty) {
        await _restoreCachedSnapshot(outletId: selectedId);
      }
    } finally {
      if (mounted && request == requestId) {
        setState(() => loading = false);
      }
    }
  }

  List<Map<String, dynamic>> _mergeOutlets(
    Iterable<Map<String, dynamic>> existing,
    Iterable<Map<String, dynamic>> incoming,
  ) {
    final map = <String, Map<String, dynamic>>{};
    for (final row in [...existing, ...incoming]) {
      final id = outletIdOf(row);
      if (id.isEmpty) continue;
      final name = outletNameOf(row);
      if (!map.containsKey(id)) {
        map[id] = {'outletId': id, 'outletName': name};
      } else if (name != 'Outlet' && name.isNotEmpty) {
        map[id]!['outletName'] = name;
      }
    }
    final rows = map.values.toList();
    rows.sort((a, b) => outletNameOf(a).compareTo(outletNameOf(b)));
    return rows;
  }

  Future<void> selectOutlet(String id, String name) async {
    final selectedId = normalizedId(id).isEmpty ? '0' : normalizedId(id);
    directItemRowsCache = [];
    billDetailsCache.clear();
    widget.onOutletChanged(selectedId, name);
    // Do not wait for the parent rebuild. Passing the explicit selected ID
    // guarantees that Outlet 1/2/3/... immediately fetches that outlet rather
    // than rendering the previous outlet's/empty data.
    await load(
      outletId: selectedId,
      forceAllOutlets: selectedId == '0',
    );
  }

  Future<void> pickDate(bool isFrom) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isFrom ? from : to,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null) return;
    if (isFrom && picked.isAfter(to)) {
      setState(() {
        from = picked;
        to = picked;
      });
    } else if (!isFrom && picked.isBefore(from)) {
      setState(() {
        to = picked;
        from = picked;
      });
    } else {
      setState(() => isFrom ? from = picked : to = picked);
    }
    // Bill details and top-item data are date-dependent. Never reuse details
    // fetched for the previous date range after the filter changes.
    billDetailsCache.clear();
    directItemRowsCache = [];
    // Invalidate any in-flight request and immediately remove the old range's
    // values. The next load snapshots the new range and repopulates the UI.
    ++requestId;
    if (mounted) {
      setState(() {
        data = {};
        previousWeekData = {};
        outletPerformanceRows = [];
        apiCombinedSummary = {};
        apiOutletRows = [];
        loading = true;
      });
    }
    await load();
  }

  List<Map<String, dynamic>> get summaries => rowsFromResponse(
        data,
        ['saleSummary', 'salesummary', 'salesSummary', 'summary', 'sale'],
        ['grosstotal', 'grosssale', 'nettotal', 'netsale', 'ordertotal'],
      );

  List<Map<String, dynamic>> get liveSales => rowsFromResponse(
        data,
        [
          'liveSale',
          'liveSales',
          'liveTable',
          'liveTables',
          'recentSales',
          'recentSale'
        ],
        ['billno', 'bill_no', 'bill_nofk', 'tableno', 'table_no'],
      );

  List<Map<String, dynamic>> get selectedSummaries {
    final id = normalizedId(widget.selectedOutlet);
    if (id != '0' && loadedOutletId == id) return summaries;
    return summaryForOutlet(
      summaries,
      widget.selectedOutlet,
      outletName: selectedOutletNameForDashboard,
    );
  }

  String get selectedOutletNameForDashboard {
    if (normalizedId(widget.selectedOutlet) == '0') return 'All Outlets';
    return outletList
            .where((o) => normalizedId(outletIdOf(o)) == normalizedId(widget.selectedOutlet))
            .map(outletNameOf)
            .firstOrNull ??
        'Outlet';
  }

  Map<String, dynamic> totals() {
    final selectedId = normalizedId(widget.selectedOutlet);
    final rows = selectedId == '0' && apiCombinedSummary.isNotEmpty
        ? <Map<String, dynamic>>[apiCombinedSummary]
        : selectedSummaries.map(normalizeApiMetricRow).toList();
    final sourceRows = rows;
    final result = <String, dynamic>{};
    const keys = [
      'grossTotal',
      'netTotal',
      'taxTotal',
      'discountTotal',
      'coverTotal',
      'apcTotal',
      'avgRevenue',
      'orderTotal',
      'voidBill',
      'modifiedBill',
      'complementary',
      'netSaleDineIn',
      'apcDineIn',
      'coverDineIn',
      'customerServed',
      'unSatteledAmount',
      'unSatteledBill',
    ];
    for (final key in keys) {
      result[key] = sourceRows.fold<num>(
        0,
        (sum, row) =>
            sum +
            number(field(row, [key, key[0].toUpperCase() + key.substring(1)])),
      );
    }
    return result;
  }

  List<Map<String, dynamic>> _itemRowsFromResponse(
      Map<String, dynamic> response) {
    final found = <Map<String, dynamic>>[];
    final seen = <String>{};
    bool looksLikeItem(Map<String, dynamic> row) {
      final keys = row.keys.map((e) => e.toString().toLowerCase()).toSet();
      final hasName = keys.any((k) =>
          k == 'i_name' || k == 'item_name' || k == 'itemname' ||
          k == 'item_name_fk' || k == 'item name' || k == 'itemdesc' ||
          k == 'item_desc' || k == 'productname' || k == 'product_name' ||
          k == 'item' || k == 'description' || k == 'name');
      final hasQty = keys.any((k) =>
          k == 'qty' || k == 'quantity' || k == 'qtyvalue' ||
          k == 'qty_value' || k == 'item_qty' || k == 'itemqty' ||
          k == 'i_qty' || k == 'sale_qty' || k == 'sold_qty' ||
          k == 'item_count' || k == 'itemcount' || k == 'item count' ||
          k == 'items_count' || k == 'itemqty' || k == 'item_qty' ||
          k == 'sold_count' || k == 'soldcount' || k == 'count');
      return hasName && hasQty;
    }
    void walk(dynamic value) {
      if (value is Map) {
        final row = Map<String, dynamic>.from(value);
        if (looksLikeItem(row)) {
          final code = stringValue(
              field(row, ['i_Code', 'item_code', 'itemCode', 'code']));
          final name = itemNameOf(row);
          final qty = itemQtyOf(row);
          final amount = itemAmountOf(row);
          final signature = '$code|$name|$qty|$amount';
          if (seen.add(signature)) found.add(row);
        }
        for (final value in row.values) {
          if (value is Map || value is List) walk(value);
        }
      } else if (value is List) {
        for (final item in value) {
          if (item is Map || item is List) walk(item);
        }
      }
    }
    for (final key in const [
      'topSellingItems', 'top_selling_items', 'topSelling', 'top_selling',
      'topItems', 'top_items', 'topSellingItem', 'top_selling_item',
      'itemSales', 'item_sales', 'popularItems', 'popular_items',
      'items', 'itemList', 'item_list', 'itemDetails', 'item_details',
      'saleItems', 'sale_items',
    ]) {
      final value = field(response, [key]);
      if (value != null) walk(value);
    }
    walk(response);
    return found;
  }

  List<Map<String, dynamic>> _aggregateItemRows(
      Iterable<Map<String, dynamic>> rows) {
    final map = <String, Map<String, dynamic>>{};
    for (final item in rows) {
      final code = stringValue(
          field(item, [
            'i_Code', 'item_code', 'itemCode', 'code', 'item_id', 'itemId'
          ]));
      final name = itemNameOf(item);
      final itemOutletId = outletIdOf(item);
      final itemOutletName = outletNameOf(item);
      final outletKey = itemOutletId.isNotEmpty
          ? itemOutletId
          : (itemOutletName == 'Outlet' ? '' : itemOutletName.trim().toLowerCase());
      final itemKey = code.isNotEmpty ? code : name.trim().toLowerCase();
      final key = '$outletKey|$itemKey';
      if (itemKey.isEmpty) continue;
      final old = map[key] ?? {
        'outletId': itemOutletId,
        'outletName': itemOutletName,
        'name': name,
        'qty': 0,
        'amount': 0,
      };
      old['qty'] = number(old['qty']) + itemQtyOf(item);
      old['amount'] = number(old['amount']) + itemAmountOf(item);
      if (old['name'] == 'Item' && name.isNotEmpty) old['name'] = name;
      if ((old['outletName'] == null || old['outletName'] == 'Outlet') &&
          itemOutletName != 'Outlet') {
        old['outletName'] = itemOutletName;
      }
      map[key] = old;
    }
    final result = map.values.toList();
    result.sort((a, b) => number(b['amount']).compareTo(number(a['amount'])));
    return result.take(10).toList();
  }

  List<Map<String, dynamic>> topItems() {
    // For a selected outlet, Dashboard/Sale was requested with that outlet ID,
    // so its item rows are already scoped. Do not discard them merely because
    // the POS omits outlet metadata on item rows. All Outlets uses the combined
    // response as-is.
    final selectedId = normalizedId(widget.selectedOutlet);
    if (selectedId != '0' && loadedOutletId == selectedId) {
      return _aggregateItemRows(directItemRowsCache);
    }
    final selected = directItemRowsCache
        .where((r) => rowMatchesOutlet(
              r,
              widget.selectedOutlet,
              outletName: selectedOutletNameForDashboard,
            ))
        .toList();
    return _aggregateItemRows(selected);
  }

  List<Map<String, dynamic>> recentSales() {
    final rows = liveSales
        .where((r) => rowMatchesOutlet(
              r,
              widget.selectedOutlet,
              outletName: selectedOutletNameForDashboard,
            ))
        .toList();
    final unique = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final key = '${outletIdOf(row)}|${outletNameOf(row).trim().toLowerCase()}|${billNoOf(row)}';
      unique[key] = row;
    }
    final result = unique.values.toList();
    result.sort((a, b) => number(billNoOf(b)).compareTo(number(billNoOf(a))));
    return result.take(10).toList();
  }

  List<Map<String, dynamic>> get previousSummaries => rowsFromResponse(
        previousWeekData,
        ['saleSummary', 'salesummary', 'salesSummary', 'summary', 'sale'],
        ['grosstotal', 'grosssale', 'nettotal', 'netsale', 'ordertotal'],
      );

  num _sumMetric(List<Map<String, dynamic>> rows, List<String> names) =>
      rows.fold<num>(0, (sum, row) => sum + number(field(row, names)));

  List<Map<String, dynamic>> outletPerformance() {
    // Chart data is deliberately independent from the dashboard card totals:
    // All Outlets needs one bar per outlet, while cards/tabs need one combined
    // total. For a selected outlet we show exactly one bar.
    // `outletPerformanceRows` is built from outlet-scoped requests and is
    // therefore the authoritative chart source. `apiOutletRows` comes from
    // the aggregate response and may expose Gross Sale as zero/derived.
    final selectedId = normalizedId(widget.selectedOutlet);
    final sourceRows = outletPerformanceRows.isNotEmpty
        ? outletPerformanceRows.map((r) => Map<String, dynamic>.from(r)).toList()
        : (selectedId == '0'
            ? apiOutletRows.map((r) => {
                'id': outletIdOf(r),
                'name': outletNameOf(r),
                'gross': number(field(r, [
                  'grossTotal', 'gross_sale', 'grossSale', 'gross_total',
                  'grossAmount', 'gross_amount', 'totalGross', 'gross',
                ])),
                'net': number(field(r, [
                  'netTotal', 'net_sale', 'netSale', 'net_total',
                  'netAmount', 'net_amount', 'totalNet', 'net',
                ])),
              }).toList()
            : <Map<String, dynamic>>[]);
    final filteredRows = sourceRows
        .where((r) => widget.selectedOutlet == '0' ||
            normalizedId(r['id']) == normalizedId(widget.selectedOutlet))
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
    // Final de-duplication guard: one visual bar per outlet ID/name.
    final unique = <String, Map<String, dynamic>>{};
    for (final row in filteredRows) {
      final id = normalizedId(row['id']);
      final name = stringValue(row['name']).trim().toLowerCase();
      final key = id.isNotEmpty && id != '0' ? 'id:$id' : 'name:$name';
      final existing = unique[key];
      if (existing == null ||
          (number(existing['gross']) == 0 && number(row['gross']) != 0)) {
        unique[key] = row;
      }
    }
    final rows = unique.values.toList();

    rows.sort((a, b) => number(b['net']).compareTo(number(a['net'])));
    return rows;
  }

  Future<void> showOutletSale(Map<String, dynamic> outlet) async {
    // The bar popup is a direct view of the same Dashboard/Sale outlet row
    // used to draw the bar. No second request and no fallback calculation.
    final outletName = stringValue(
      outlet['name'] ?? outlet['outletName'] ?? outlet['outlet_name'],
      'Outlet',
    ).trim();
    final displayGross = number(outlet['gross']);
    final displayNet = number(outlet['net']);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF111633),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text(outletName,
            style: const TextStyle(fontWeight: FontWeight.w900)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.receipt_long_rounded, color: Colors.orangeAccent),
            title: const Text('Gross Sale'),
            trailing: Text(money(displayGross), style: const TextStyle(fontWeight: FontWeight.w900)),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.trending_up_rounded, color: Colors.cyanAccent),
            title: const Text('Net Sale'),
            trailing: Text(money(displayNet), style: const TextStyle(fontWeight: FontWeight.w900)),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Close')),
        ],
      ),
    );
  }

  Widget outletPerformanceCard() {
    final rows = outletPerformance();
    if (rows.isEmpty) {
      return SectionCard(
        eyebrow: 'OUTLET PERFORMANCE',
        title: 'Net Sale by Outlet',
        child: const EmptyText('No outlet-wise sale data available.'),
      );
    }
    final maxNet = rows.fold<num>(0,
        (m, r) => number(r['net']) > m ? number(r['net']) : m);
    final palette = <Color>[
      const Color(0xFF00D4FF), const Color(0xFF8B5CF6),
      const Color(0xFFFF7A59), const Color(0xFF22C55E),
      const Color(0xFFF59E0B), const Color(0xFFEC4899),
    ];

    // Keep an outlet's chart colour stable when the filter changes. Previously
    // the selected outlet became index 0 after filtering, so Outlet 2 changed
    // from purple to Outlet 1's cyan. Resolve the palette slot from the
    // outlet's real ID/name instead of the filtered list index.
    Color outletChartColor(Map<String, dynamic> row, int fallbackIndex) {
      final id = normalizedId(stringValue(
        row['id'] ?? row['outletId'] ?? row['outlet_id'],
        '',
      ));
      final name = stringValue(
        row['name'] ?? row['outletName'] ?? row['outlet_name'],
        '',
      ).trim().toLowerCase();
      final sourceIndex = outletList.indexWhere((o) {
        final outletId = outletIdOf(o);
        final outletName = outletNameOf(o).trim().toLowerCase();
        return (id.isNotEmpty && id != '0' && outletId == id) ||
            (name.isNotEmpty && outletName == name);
      });
      return palette[(sourceIndex >= 0 ? sourceIndex : fallbackIndex) % palette.length];
    }

    return SectionCard(
      eyebrow: 'OUTLET PERFORMANCE',
      title: 'Net Sale by Outlet',
      child: Column(children: [
        Row(children: [
          const Icon(Icons.touch_app_rounded, size: 16, color: Colors.white54),
          const SizedBox(width: 6),
          const Expanded(child: Text('Tap a bar for Gross Sale + Net Sale',
              style: TextStyle(color: Colors.white60, fontSize: 11))),
        ]),
        const SizedBox(height: 16),
        SizedBox(
          height: 230,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: rows.asMap().entries.map((entry) {
                final i = entry.key;
                final r = entry.value;
                final net = number(r['net']);
                final h = maxNet <= 0 ? 14.0 : 18 + (net / maxNet) * 150;
                final c = outletChartColor(r, i);
                return SizedBox(
                  width: 92,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => showOutletSale(r),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(compactMoney(net),
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900)),
                          const SizedBox(height: 6),
                          Container(
                            height: h.toDouble(),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [c, c.withValues(alpha: .25)],
                              ),
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [BoxShadow(color: c.withValues(alpha: .18), blurRadius: 14, spreadRadius: 1)],
                            ),
                          ),
                          const SizedBox(height: 7),
                          Text(stringValue(r['name'], 'Outlet'),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white70, fontSize: 9, fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ]),
    );
  }

  Widget metric(
    String title,
    dynamic value, {
    bool count = false,
    num percentage = 0,
    bool isIncrease = true,
  }) {
    final accent = title.contains('Net')
        ? const Color(0xFF00D4FF)
        : title.contains('Gross')
            ? const Color(0xFFFFB547)
            : const Color(0xFF8B5CF6);
    final trendColor =
        isIncrease ? const Color(0xFF00E676) : const Color(0xFFFF5252);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E2238),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
            ],
          ),
          FittedBox(
            alignment: Alignment.centerLeft,
            fit: BoxFit.scaleDown,
            child: Text(
              count ? number(value).toStringAsFixed(0) : money(value),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Row(
            children: [
              Icon(
                isIncrease ? Icons.arrow_upward : Icons.arrow_downward,
                size: 13,
                color: trendColor,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  '${percentage.toStringAsFixed(2)}% ${isIncrease ? 'increase' : 'decrease'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: trendColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Map<String, num> _cardMetrics(List<Map<String, dynamic>> rows) {
    num sum(List<String> names) => _sumMetric(rows, names);
    return {
      'Gross Sale': sum(['grossTotal', 'grossSale', 'gross_sale', 'grossAmount', 'totalGross', 'gross', 'gross_total', 'total_gross']),
      'Net Sale': sum(['netTotal', 'netSale', 'net_sale', 'netAmount', 'totalNet', 'net', 'net_total', 'total_net']),
      'Tax': sum(['taxTotal', 'tax', 'taxAmount', 'totalTax']),
      'Discount': sum(['discountTotal', 'discount', 'discountAmount', 'totalDiscount']),
      'Covers': sum(['coverTotal', 'cover', 'covers', 'pax']),
      'APC': sum(['apcTotal', 'apc', 'averagePerCover']),
      'Avg Revenue / Bill': sum(['avgRevenue', 'averageRevenue', 'avgRevenuePerBill']),
      'Orders': sum(['orderTotal', 'orders', 'billCount', 'bill_count']),
      'Void Bills': sum(['voidBill', 'voidBills', 'voidBillCount']),
      'Modified Bills': sum(['modifiedBill', 'modifiedBills', 'modifiedBillCount']),
      'Complimentary': sum(['complementary', 'complimentary', 'complementaryBill', 'complementaryBills']),
      'Customers Served': sum(['customerServed', 'customersServed', 'customerCount']),
      'Dine-In Net Sale': sum(['netSaleDineIn', 'dineInNetSale', 'dine_in_net_sale']),
      'Dine-In APC': sum(['apcDineIn', 'dineInApc', 'dine_in_apc']),
      'Unsettled Amount': sum(['unSatteledAmount', 'unsettledAmount', 'unSettledAmount']),
      'Unsettled Bills': sum(['unSatteledBill', 'unsettledBill', 'unSettledBill']),
    };
  }

  num _change(num current, num previous) {
    if (previous == 0) {
      if (current == 0) return 0;
      return 100;
    }
    return ((current - previous) / previous) * 100;
  }

  String _cardTotalKey(String title) {
    const keys = <String, String>{
      'Gross Sale': 'grossTotal',
      'Net Sale': 'netTotal',
      'Tax': 'taxTotal',
      'Discount': 'discountTotal',
      'Covers': 'coverTotal',
      'APC': 'apcTotal',
      'Avg Revenue / Bill': 'avgRevenue',
      'Orders': 'orderTotal',
      'Void Bills': 'voidBill',
      'Modified Bills': 'modifiedBill',
      'Complimentary': 'complementary',
      'Customers Served': 'customerServed',
      'Dine-In Net Sale': 'netSaleDineIn',
      'Dine-In APC': 'apcDineIn',
      'Unsettled Amount': 'unSatteledAmount',
      'Unsettled Bills': 'unSatteledBill',
    };
    return keys[title] ?? title;
  }

  @override
  Widget build(BuildContext context) {
    final t = totals();
    final currentCardMetrics = _cardMetrics(selectedSummaries);
    final previousRows = previousLoadedOutletId == normalizedId(widget.selectedOutlet) &&
            normalizedId(widget.selectedOutlet) != '0'
        ? previousSummaries
        : previousSummaries.where((r) => rowMatchesOutlet(
              r,
              widget.selectedOutlet,
              outletName: selectedOutletNameForDashboard,
            )).toList();
    final previousCardMetrics = _cardMetrics(previousRows);

    (num, bool) cardTrend(String title) {
      final current =
          number(currentCardMetrics[title] ?? t[_cardTotalKey(title)] ?? 0);
      final previous = number(previousCardMetrics[title] ?? 0);
      final change = _change(current, previous);
      return (change.abs(), change >= 0);
    }

    final recent = recentSales();
    final items = topItems();
    final outletName = widget.selectedOutlet == '0'
        ? 'All Outlets'
        : outletList
                .where((o) => outletIdOf(o) == widget.selectedOutlet)
                .map(outletNameOf)
                .firstOrNull ??
            'Outlet';

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset('assets/app_icon.png', width: 34, height: 34),
            const SizedBox(width: 10),
            const Expanded(
                child: Text(appTitle,
                    style: TextStyle(fontWeight: FontWeight.w800))),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                Colors.cyanAccent.withValues(alpha: .18),
                Colors.purpleAccent.withValues(alpha: .12)
              ]),
              border:
                  Border.all(color: Colors.cyanAccent.withValues(alpha: .55)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: loading
                  ? null
                  : () async {
                      widget.onLiveSync();
                      await load(resetOutlet: true);
                    },
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.radar_rounded, size: 16, color: Colors.cyanAccent),
                    SizedBox(width: 5),
                    Text('LIVE',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            letterSpacing: .8)),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
              onPressed: loading ? null : () => load(resetOutlet: true),
              icon: const Icon(Icons.refresh)),
          IconButton(
              onPressed: widget.onLogout, icon: const Icon(Icons.logout)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => load(resetOutlet: true),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Text('OVERVIEW',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.secondary,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5)),
            const SizedBox(height: 4),
            const Text('Dashboard',
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
            Text('Welcome, ${widget.loginId} · $outletName',
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Row(children: [
                      Expanded(
                          child: _dateButton(dateText(from),
                              Icons.calendar_today, () => pickDate(true))),
                      const SizedBox(width: 10),
                      Expanded(
                          child: _dateButton(dateText(to), Icons.event,
                              () => pickDate(false))),
                    ]),
                    const SizedBox(height: 12),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: [
                        ChoiceChip(
                          label: const Text('All Outlets',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          selected: widget.selectedOutlet == '0',
                          onSelected: (_) => selectOutlet('0', 'All Outlets'),
                        ),
                        ...outletList.map((o) {
                          final id = outletIdOf(o);
                          final name = outletNameOf(o);
                          return Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: ChoiceChip(
                              label: Text(name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                              selected: widget.selectedOutlet == id,
                              onSelected: (_) => selectOutlet(id, name),
                            ),
                          );
                        }),
                      ]),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            outletPerformanceCard(),
            const SizedBox(height: 14),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: MediaQuery.sizeOf(context).width > 700 ? 4 : 2,
              childAspectRatio: 1.6,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              children: [
                metric('Gross Sale', t['grossTotal'], percentage: cardTrend('Gross Sale').$1, isIncrease: cardTrend('Gross Sale').$2),
                metric('Net Sale', t['netTotal'], percentage: cardTrend('Net Sale').$1, isIncrease: cardTrend('Net Sale').$2),
                metric('Tax', t['taxTotal'], percentage: cardTrend('Tax').$1, isIncrease: cardTrend('Tax').$2),
                metric('Discount', t['discountTotal'], percentage: cardTrend('Discount').$1, isIncrease: cardTrend('Discount').$2),
                metric('Covers', t['coverTotal'], count: true, percentage: cardTrend('Covers').$1, isIncrease: cardTrend('Covers').$2),
                metric('APC', t['apcTotal'], percentage: cardTrend('APC').$1, isIncrease: cardTrend('APC').$2),
                metric('Avg Revenue / Bill', t['avgRevenue'], percentage: cardTrend('Avg Revenue / Bill').$1, isIncrease: cardTrend('Avg Revenue / Bill').$2),
                metric('Orders', t['orderTotal'], count: true, percentage: cardTrend('Orders').$1, isIncrease: cardTrend('Orders').$2),
                metric('Void Bills', t['voidBill'], count: true, percentage: cardTrend('Void Bills').$1, isIncrease: cardTrend('Void Bills').$2),
                metric('Modified Bills', t['modifiedBill'], count: true, percentage: cardTrend('Modified Bills').$1, isIncrease: cardTrend('Modified Bills').$2),
                metric('Complimentary', t['complementary'], count: true, percentage: cardTrend('Complimentary').$1, isIncrease: cardTrend('Complimentary').$2),
                metric('Customers Served', t['customerServed'], count: true, percentage: cardTrend('Customers Served').$1, isIncrease: cardTrend('Customers Served').$2),
                metric('Dine-In Net Sale', t['netSaleDineIn'], percentage: cardTrend('Dine-In Net Sale').$1, isIncrease: cardTrend('Dine-In Net Sale').$2),
                metric('Dine-In APC', t['apcDineIn'], percentage: cardTrend('Dine-In APC').$1, isIncrease: cardTrend('Dine-In APC').$2),
                metric('Unsettled Amount', t['unSatteledAmount'], percentage: cardTrend('Unsettled Amount').$1, isIncrease: cardTrend('Unsettled Amount').$2),
                metric('Unsettled Bills', t['unSatteledBill'], count: true, percentage: cardTrend('Unsettled Bills').$1, isIncrease: cardTrend('Unsettled Bills').$2),
              ],
            ),
            const SizedBox(height: 16),
            SectionCard(
              eyebrow: 'TRANSACTIONS',
              title: 'Recent Sales',
              child: recent.isEmpty
                  ? const EmptyText('No recent sales returned by POS')
                  : Column(
                      children: [
                        _dataHeaderRow(
                          const ['#Bill', 'Outlet Name', 'Gross Total'],
                          const [0.85, 1.65, 1.25],
                        ),
                        const Divider(height: 1),
                        ...recent.map((r) => _recentSaleRow(r)),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Showing 1 to ${recent.length} of ${recent.length} entries',
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 14),
            SectionCard(
              eyebrow: 'PERFORMANCE',
              title: 'Top Selling Items',
              child: items.isEmpty
                  ? const EmptyText('No item sales returned by POS')
                  : Column(
                      children: [
                        _dataHeaderRow(
                          const ['Outlet Name', 'Item Name', 'Item Count'],
                          const [1.55, 2.15, 0.75],
                        ),
                        const Divider(height: 1),
                        ...items.map((r) => _topItemRow(r)),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Showing 1 to ${items.length} of ${items.length} entries',
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dataHeaderRow(List<String> labels, List<double> flexes) =>
      Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: List.generate(labels.length, (i) => Expanded(
                flex: (flexes[i] * 100).round(),
                child: Text(
                  labels[i],
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              )),
        ),
      );

  Widget _recentSaleRow(Map<String, dynamic> r) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 85, child: Text(billNoOf(r).isEmpty ? '—' : billNoOf(r))),
            Expanded(flex: 165, child: Text(outletNameOf(r))),
            Expanded(
              flex: 125,
              child: Text(
                money(billAmountOf(r)),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      );

  Widget _topItemRow(Map<String, dynamic> r) {
    final qty = itemQtyOf(r);
    final outlet = outletNameOf(r) == 'Outlet'
        ? selectedOutletNameForDashboard
        : outletNameOf(r);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 38,
            child: CircleAvatar(
              radius: 16,
              backgroundColor: const Color(0xFF6D4CB3),
              child: Text(
                qty.toStringAsFixed(0),
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  itemNameOf(r),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  outlet,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 42,
            child: Text(
              qty.toStringAsFixed(0),
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dateButton(String text, IconData icon, VoidCallback onTap) =>
      OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(text, overflow: TextOverflow.ellipsis),
      );
}

class SectionCard extends StatelessWidget {
  final String? eyebrow;
  final String title;
  final Widget child;
  const SectionCard(
      {super.key, this.eyebrow, required this.title, required this.child});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (eyebrow != null)
              Text(eyebrow!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.secondary,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5)),
            const SizedBox(height: 3),
            Text(title,
                style:
                    const TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            child,
          ]),
        ),
      );
}

class EmptyText extends StatelessWidget {
  final String text;
  const EmptyText(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(18),
        child: Center(
            child: Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70))),
      );
}

class LiveTablesPage extends StatefulWidget {
  final ApiService api;
  final String outletId;
  final String outletName;
  final List<Map<String, dynamic>> availableOutlets;
  final ValueNotifier<int> syncSignal;
  final Future<void> Function() onLogout;

  const LiveTablesPage({
    super.key,
    required this.api,
    required this.outletId,
    required this.outletName,
    this.availableOutlets = const [],
    required this.syncSignal,
    required this.onLogout,
  });

  @override
  State<LiveTablesPage> createState() => _LiveTablesPageState();
}

class _LiveTablesPageState extends State<LiveTablesPage> {
  List<Map<String, dynamic>> live = [];
  List<Map<String, dynamic>> summaryRows = [];
  bool loading = false;
  Timer? timer;
  String selectedOutletId = '0';
  late final VoidCallback _syncListener;

  @override
  void initState() {
    super.initState();
    selectedOutletId = widget.outletId.trim().isEmpty ? '0' : widget.outletId.trim();
    _syncListener = () {
      if (mounted && !loading) load();
    };
    widget.syncSignal.addListener(_syncListener);
    _restoreCachedLive().then((_) => load());
    timer = Timer.periodic(
      const Duration(seconds: refreshSeconds),
      (_) => load(),
    );
  }

  @override
  void dispose() {
    widget.syncSignal.removeListener(_syncListener);
    timer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant LiveTablesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.syncSignal != widget.syncSignal) {
      oldWidget.syncSignal.removeListener(_syncListener);
      widget.syncSignal.addListener(_syncListener);
    }
    final oldId = normalizedId(oldWidget.outletId).isEmpty
        ? '0'
        : normalizedId(oldWidget.outletId);
    final newId = normalizedId(widget.outletId).isEmpty
        ? '0'
        : normalizedId(widget.outletId);
    if (oldId != newId ||
        oldWidget.outletName != widget.outletName ||
        oldWidget.availableOutlets.length != widget.availableOutlets.length) {
      selectedOutletId = newId;
      load(resetOutlet: false);
    }
  }

  Future<void> _restoreCachedLive() async {
    final cacheId = normalizedId(widget.outletId).isEmpty ? '0' : normalizedId(widget.outletId);
    final cached = await OfflineStore.read('live_$cacheId');
    if (!mounted || cached == null) return;
    final response = responseMap(cached);
    if (response.isEmpty) return;
    final rows = rowsFromResponse(
      response,
      [
        'liveSale',
        'liveSales',
        'liveTable',
        'liveTables',
        'recentSales',
        'recentSale'
      ],
      ['billno', 'bill_no', 'bill_nofk', 'tableno', 'table_no'],
    );
    final summaries = rowsFromResponse(
      response,
      ['saleSummary', 'salesummary', 'salesSummary', 'summary', 'sale'],
      ['grosstotal', 'grosssale', 'nettotal', 'netsale', 'ordertotal'],
    );
    if (rows.isEmpty && summaries.isEmpty) return;
    final scopedRows = cacheId == '0'
        ? rows.where((row) => outletIdOf(row).isNotEmpty).toList()
        : rows
            .where((row) => rowMatchesOutlet(
                  row,
                  cacheId,
                  outletName: selectedOutletNameForLive(cacheId),
                ))
            .toList();
    final scopedSummaries = cacheId == '0'
        ? summaries.where((row) => outletIdOf(row).isNotEmpty).toList()
        : summaries
            .where((row) => rowMatchesOutlet(
                  row,
                  cacheId,
                  outletName: selectedOutletNameForLive(cacheId),
                ))
            .toList();
    setState(() {
      live = scopedRows;
      summaryRows = scopedSummaries;
      selectedOutletId = cacheId;
    });
  }

  Future<Map<String, dynamic>> _loadLiveFor(String outletId) async {
    final now = DateTime.now();
    final id = normalizedId(outletId).isEmpty ? '0' : normalizedId(outletId);

    // Dashboard/Sale is discovery-only here: it gives us the bill numbers that
    // have to be passed to LiveTableItem/Sale. No Live Tables metric is taken
    // from Dashboard/Sale.
    final discovery = responseMap(await widget.api
        .dashboard(
          apiDate(now),
          apiDate(now),
          id,
          useOutletFilter: id != '0',
        )
        .timeout(const Duration(seconds: 20)));
    final candidates = rowsFromResponse(
      discovery,
      [
        'liveSale',
        'liveSales',
        'liveTable',
        'liveTables',
        'recentSales',
        'recentSale',
        'saleSummary',
        'salesummary',
        'salesSummary',
        'summary',
        'sale'
      ],
      ['billno', 'bill_no', 'bill_nofk', 'tableno', 'table_no'],
    );

    final scoped = candidates.where((row) {
      final bill = billNoOf(row).trim();
      if (bill.isEmpty) return false;
      return id == '0'
          ? outletIdOf(row).isNotEmpty
          : rowMatchesOutlet(
              row,
              id,
              outletName: selectedOutletNameForLive(id),
            );
    }).toList();

    final unique = <String, Map<String, dynamic>>{};
    for (final row in scoped) {
      final rowOutlet = outletIdOf(row).isEmpty ? id : outletIdOf(row);
      if (rowOutlet.isEmpty || rowOutlet == '0') continue;
      final bill = billNoOf(row).trim();
      unique['$rowOutlet|$bill'] = row;
    }

    final enriched = <Map<String, dynamic>>[];
    Map<String, dynamic>? authoritativeOutletSummary;
    const concurrency = 4;
    final entries = unique.entries.toList();
    for (var offset = 0; offset < entries.length; offset += concurrency) {
      final batch = entries.skip(offset).take(concurrency).toList();
      final results = await Future.wait(batch.map((entry) async {
        final base = Map<String, dynamic>.from(entry.value);
        final discoveryTableName = tableDisplayNameOf(base);
        if (discoveryTableName != '—' && discoveryTableName.trim().isNotEmpty) {
          base['t_Name'] = discoveryTableName;
        }
        try {
          final detail = responseMap(await widget.api
              .liveTable(entry.key.split('|').first, entry.key.split('|').last)
              .timeout(const Duration(seconds: 20)));
          final detailRow = _liveDetailSummaryRow(detail);
          // LiveTableItem/Sale repeats outlet-level financial totals on each
          // bill response. Keep the first successful original summary once per
          // outlet; summing it once per bill was the reason Pending/Gross/Net
          // were doubled. Table rows still retain every bill detail.
          authoritativeOutletSummary ??= <String, dynamic>{
            ...detailRow,
            if (outletIdOf(detailRow).isEmpty)
              'outlet_id': entry.key.split('|').first,
            if (outletNameOf(detailRow) == 'Outlet')
              'outlet_name': selectedOutletNameForLive(entry.key.split('|').first),
          };
          final merged = <String, dynamic>{...base, ...detailRow};
          // Never lose the discovery identity when a detail response omits it.
          if (outletIdOf(merged).isEmpty) merged['outlet_id'] = entry.key.split('|').first;
          if (billNoOf(merged).isEmpty) merged['bill_no'] = entry.key.split('|').last;
          return merged;
        } catch (_) {
          // A failed bill-detail request is not allowed to turn a stale or
          // partial Dashboard row into a fake Live Table metric. Keep the row
          // only as a visual fallback; all financial totals below ignore rows
          // without authoritative LiveTableItem/Sale fields.
          return <String, dynamic>{
            ...base,
            '_liveDetailFailed': true,
          };
        }
      }));
      enriched.addAll(results);
    }

    return {
      'liveSale': enriched,
      // Exactly one authoritative LiveTableItem/Sale summary per outlet.
      // Never sum repeated outlet-level summary values across bills.
      'saleSummary': authoritativeOutletSummary == null
          ? <Map<String, dynamic>>[]
          : <Map<String, dynamic>>[authoritativeOutletSummary!],
    };
  }

  String _findTableNameInResponse(
    Map<String, dynamic> response, {
    String billNo = '',
  }) {
    const nameKeys = [
      't_Name', 't_name', 'tName', 'TName', 'T_Name',
      'tableName', 'table_name', 'TableName', 'Table_Name',
      'table_name_fk', 'tableNameFk', 'tableDesc', 'table_desc',
      'tableDescription', 'table_description', 'tableDisplayName',
      'table_display_name', 'displayTableName', 'tableLabel', 'table_label',
      'tblName', 'tbl_name', 'table_name_fk_value',
    ];
    String best = '';
    var bestScore = -1;

    void inspect(dynamic value) {
      if (value is Map) {
        final row = Map<String, dynamic>.from(value);
        final candidate = stringValue(field(row, nameKeys), '').trim();
        if (candidate.isNotEmpty && candidate != '—' && candidate != '-' && candidate != '0') {
          var score = 1;
          final wantedBill = billNo.trim();
          if (wantedBill.isNotEmpty && billNoOf(row).trim() == wantedBill) score += 20;
          final rawTable = stringValue(field(row, [
            'tableNo', 'tableno', 'table_No', 'table_no', 'TableNo', 'Table_No'
          ]), '').trim();
          if (rawTable.isNotEmpty && rawTable != '—' && rawTable != '-') score += 2;
          if (score > bestScore) {
            bestScore = score;
            best = candidate;
          }
        }
        for (final child in row.values) {
          if (child is Map || child is List) inspect(child);
        }
      } else if (value is List) {
        for (final child in value) {
          if (child is Map || child is List) inspect(child);
        }
      }
    }

    inspect(response);
    final directTable = field(response, ['table']);
    if (best.isEmpty && directTable is String && directTable.trim().isNotEmpty) {
      best = directTable.trim();
    }
    return best;
  }

  Map<String, dynamic> _bestFinancialRow(Map<String, dynamic> response) {
    const financialKeys = [
      'grossTotal', 'grossSale', 'gross_sale', 'grosssale', 'gross_total',
      'grossAmount', 'gross_amount', 'totalGross', 'gross',
      'netTotal', 'netSale', 'net_sale', 'netsale', 'net_total',
      'netAmount', 'net_amount', 'totalNet', 'net',
      'pendingAmt', 'pendingAmount', 'pending_amt', 'pending_amount',
      'unSatteledAmount', 'unSettledAmount', 'unsettledAmount',
      'settlementPending', 'pendingSettlement',
    ];
    Map<String, dynamic> best = {};
    var bestScore = -1;

    void inspect(dynamic value) {
      if (value is Map) {
        final row = Map<String, dynamic>.from(value);
        var score = 0;
        for (final key in financialKeys) {
          if (field(row, [key]) != null) score++;
        }
        final hasBill = billNoOf(row).trim().isNotEmpty;
        final hasTable = tableNoOf(row).trim().isNotEmpty &&
            tableNoOf(row).trim() != '—';
        if (hasBill) score += 3;
        if (hasTable) score += 2;
        final hasGross = financialKeys.take(9).any((key) => field(row, [key]) != null);
        final hasNet = financialKeys.skip(9).take(9).any((key) => field(row, [key]) != null);
        final hasPending = financialKeys.skip(18).any((key) => field(row, [key]) != null);
        if (hasGross && hasNet && hasPending) score += 10;
        if (score > bestScore) {
          bestScore = score;
          best = row;
        }
        for (final child in row.values) {
          if (child is Map || child is List) inspect(child);
        }
      } else if (value is List) {
        for (final child in value) {
          if (child is Map || child is List) inspect(child);
        }
      }
    }

    inspect(response);
    return best;
  }

  Map<String, dynamic> _liveDetailSummaryRow(Map<String, dynamic> response) {
    final direct = <String, dynamic>{};
    final detailRows = rowsFromResponse(
      response,
      [
        'sale',
        'sales',
        'saleDetail',
        'saleSummary',
        'salesummary',
        'salesSummary',
        'summary',
        'bill',
        'billDetail',
        'liveSale',
        'liveTable',
        'liveTables'
      ],
      [
        'grosssale',
        'gross_sale',
        'grosstotal',
        'netsale',
        'net_sale',
        'nettotal',
        'pendingamt',
        'pendingamount',
        'tableno',
        'table_no'
      ],
    );
    final bestFinancial = _bestFinancialRow(response);
    if (bestFinancial.isNotEmpty) {
      direct.addAll(bestFinancial);
    } else if (detailRows.isNotEmpty) {
      direct.addAll(detailRows.first);
    }

    // Preserve the POS master table name even when it lives in a different
    // nested object/row than the financial summary. The UI label remains
    // `Table No:` but its value must be the original name (TB1/WS1/etc.).
    final tableName = _findTableNameInResponse(response, billNo: billNoOf(direct));
    if (tableName.isNotEmpty) {
      direct['t_Name'] = tableName;
    }

    // Some deployments return the financial fields at the root and the item
    // list under `itms`. Preserve root fields as the highest-level source.
    for (final key in [
      'outlet_id',
      'outletId',
      'outlet_name',
      'outletName',
      'bill_no',
      'billNo',
      'table_no',
      'tableNo',
      'tableno',
      't_Name',
      't_name',
      'tName',
      'tableName',
      'table_name',
      'TableName',
      'Table_Name',
      'tableDisplayName',
      'table_display_name',
      'bill_status',
      'billStatus',
      'status',
      'grossSale',
      'gross_sale',
      'grossTotal',
      'gross_total',
      'grosssale',
      'grossSales',
      'gross_sales',
      'grossAmount',
      'gross_amount',
      'totalGross',
      'total_gross',
      'gross',
      'netSale',
      'net_sale',
      'netTotal',
      'net_total',
      'netsale',
      'netAmount',
      'net_amount',
      'totalNet',
      'total_net',
      'net',
      'pendingAmt',
      'pendingAmount',
      'pending_amt',
      'pending_amount',
      'unSatteledAmount',
      'unSettledAmount',
      'unsettledAmount',
      'settlementPending',
      'pendingSettlement',
      'cover',
      'pax',
      'bill_time',
      'billTime',
      'time'
    ]) {
      final value = field(response, [key]);
      if (value != null) direct[key] = value;
    }
    return direct;
  }

  List<Map<String, dynamic>> _scopeLiveRows(
      Iterable<Map<String, dynamic>> rows, String outletId) {
    final id = normalizedId(outletId);
    if (id.isEmpty || id == '0') {
      // In All Outlets mode never manufacture outlet ownership. A row without
      // outlet metadata cannot be safely assigned to any outlet.
      return rows.where((row) => outletIdOf(row).isNotEmpty).toList();
    }
    // Even though the API is requested with an outlet id, some POS versions
    // ignore that parameter and return the aggregate dataset. Therefore a
    // selected outlet may only receive rows that positively identify that
    // outlet by id or name. Never attach the selected id blindly.
    return rows
        .where((row) => rowMatchesOutlet(
              row,
              id,
              outletName: selectedOutletNameForLive(id),
            ))
        .toList();
  }

  String selectedOutletNameForLive(String id) {
    for (final outlet in widget.availableOutlets) {
      if (outletIdOf(outlet) == id) return outletNameOf(outlet);
    }
    if (widget.outletId == id && widget.outletName.trim().isNotEmpty) {
      return widget.outletName.trim();
    }
    return '';
  }

  List<Map<String, dynamic>> _extractLive(Map<String, dynamic> response) =>
      rowsFromResponse(
        response,
        ['liveSale', 'liveSales', 'liveTable', 'liveTables', 'recentSales', 'recentSale'],
        ['billno', 'bill_no', 'bill_nofk', 'tableno', 'table_no'],
      );

  List<Map<String, dynamic>> _extractSummary(Map<String, dynamic> response) =>
      rowsFromResponse(
        response,
        ['saleSummary', 'salesummary', 'salesSummary', 'summary', 'sale'],
        ['grosstotal', 'grosssale', 'nettotal', 'netsale', 'ordertotal'],
      );

  Future<void> load({bool resetOutlet = false}) async {
    if (loading) return;
    final selected = resetOutlet
        ? '0'
        : (normalizedId(selectedOutletId).isEmpty
            ? '0'
            : normalizedId(selectedOutletId));
    if (resetOutlet) setState(() => selectedOutletId = '0');
    if (mounted) setState(() => loading = true);

    try {
      final allLive = <Map<String, dynamic>>[];
      final allSummary = <Map<String, dynamic>>[];

      if (selected == '0') {
        final ids = widget.availableOutlets
            .map(outletIdOf)
            .where((id) => id.isNotEmpty && id != '0')
            .toSet()
            .toList();
        if (ids.isEmpty) {
          final response = await _loadLiveFor('0');
          allLive.addAll(_extractLive(response));
          allSummary.addAll(_extractSummary(response));
        } else {
          final results = await Future.wait(ids.map((id) async {
            try {
              final response = await _loadLiveFor(id);
              return (
                live: _scopeLiveRows(_extractLive(response), id),
                summary: _scopeLiveRows(_extractSummary(response), id),
              );
            } catch (_) {
              return (
                live: <Map<String, dynamic>>[],
                summary: <Map<String, dynamic>>[],
              );
            }
          }));
          for (final result in results) {
            allLive.addAll(result.live);
            allSummary.addAll(result.summary);
          }
        }
      } else {
        final response = await _loadLiveFor(selected);
        allLive.addAll(_scopeLiveRows(_extractLive(response), selected));
        allSummary.addAll(_scopeLiveRows(_extractSummary(response), selected));
      }

      if (!mounted) return;
      setState(() {
        live = allLive;
        summaryRows = allSummary;
        selectedOutletId = selected;
      });
      await OfflineStore.save('live_$selected', {
        'liveSale': allLive,
        'saleSummary': allSummary,
      });
    } catch (_) {
      // Keep the last successful snapshot; the next 60-second sync retries.
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  List<Map<String, dynamic>> get outlets {
    final map = <String, Map<String, dynamic>>{};
    for (final row in [...live, ...summaryRows]) {
      final id = outletIdOf(row);
      if (id.isEmpty) continue;
      final name = outletNameOf(row);
      final existing = map[id];
      map[id] = {
        'outletId': id,
        'outletName': name == 'Outlet' && existing != null
            ? outletNameOf(existing)
            : name,
      };
    }
    for (final outlet in widget.availableOutlets) {
      final id = outletIdOf(outlet);
      if (id.isEmpty || id == '0') continue;
      map[id] = {
        'outletId': id,
        'outletName': outletNameOf(outlet),
      };
    }
    final result = map.values.toList();
    result.sort((a, b) => outletNameOf(a).compareTo(outletNameOf(b)));
    return result;
  }

  bool _isActualLiveTable(Map<String, dynamic> row) {
    final table = tableNoOf(row).trim();
    final bill = billNoOf(row).trim();
    if (table.isEmpty || table == '—' || table == '-' || table == '0') {
      // Dashboard/Sale also returns recent/settled bills. Those rows often have
      // no table number, and must never be shown as Running Tables.
      return false;
    }
    if (bill.isEmpty) return false;
    final rawStatus = field(row, ['bill_status', 'billStatus', 'status']);
    if (rawStatus == null) return true;
    final status = rawStatus.toString().trim().toLowerCase();
    return status == '0' || status == 'running' || status == 'open' ||
        status == 'active' || status == 'inprogress' || status == 'in progress';
  }

  List<Map<String, dynamic>> get liveTableCandidates => live
      .where((r) => rowMatchesOutlet(
            r,
            selectedOutletId,
            outletName: selectedOutletName,
          ))
      .where((r) {
        final table = tableNoOf(r).trim();
        final bill = billNoOf(r).trim();
        return table.isNotEmpty &&
            table != '—' &&
            table != '-' &&
            table != '0' &&
            bill.isNotEmpty;
      })
      .toList();

  List<Map<String, dynamic>> get selectedLive => liveTableCandidates
      .where((r) => r['_liveDetailFailed'] != true)
      .where(_isActualLiveTable)
      .where((r) => rowMatchesOutlet(
            r,
            selectedOutletId,
            outletName: selectedOutletName,
          ))
      .toList();

  List<Map<String, dynamic>> get selectedSummaries => summaryRows
      .where((r) => r['_liveDetailFailed'] != true)
      .where((r) => rowMatchesOutlet(
            r,
            selectedOutletId,
            outletName: selectedOutletName,
          ))
      .toList();

  num _sumRows(List<Map<String, dynamic>> rows, List<String> names) =>
      rows.fold<num>(0, (sum, row) => sum + number(field(row, names)));

  num _metric(List<String> liveNames, List<String> summaryNames) {
    // Live Tables financial cards have exactly one source of truth:
    // LiveTableItem/Sale response rows. Never fall back to table-card values,
    // Dashboard/Sale, Net Sale, Avg Revenue, Order Count, or any derived value.
    // All Outlets aggregates the original API field across outlet-scoped rows;
    // a single outlet uses only that outlet's original API rows.
    if (selectedSummaries.isEmpty) return 0;
    return _sumRows(selectedSummaries, summaryNames);
  }

  String get selectedOutletName {
    if (selectedOutletId == '0') return 'All Outlets';
    for (final outlet in outlets) {
      if (outletIdOf(outlet) == selectedOutletId) return outletNameOf(outlet);
    }
    return widget.outletName.isEmpty ? 'Outlet' : widget.outletName;
  }

  int get runningCount => selectedLive.length;

  int get completedCount => liveTableCandidates
      .where((r) => !_isActualLiveTable(r))
      .length;

  Future<void> openTable(Map<String, dynamic> table) async {
    final outlet =
        outletIdOf(table).isEmpty ? selectedOutletId : outletIdOf(table);
    final bill = billNoOf(table);
    if (bill.isEmpty || outlet.isEmpty || outlet == '0') return;

    final future = widget.api.liveTable(outlet, bill).then(responseMap);
    Timer? autoClose;
    final dialogFuture = showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return Dialog(
          insetPadding: const EdgeInsets.all(18),
          backgroundColor: const Color(0xFF10152F),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          child: FutureBuilder<Map<String, dynamic>>(
            future: future,
            builder: (context, snapshot) {
              final detail = snapshot.data;
              final items =
                  asRows(field(detail ?? {}, ['itms', 'items', 'itemList']));
              return ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: 620, maxHeight: 720),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Table No: ${tableDisplayNameOf(table)}',
                              style: const TextStyle(
                                  fontSize: 24, fontWeight: FontWeight.w900),
                            ),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(dialogContext).pop(),
                            style: TextButton.styleFrom(
                                foregroundColor: Colors.redAccent),
                            child: const Text(
                              'CUT',
                              style: TextStyle(
                                  fontWeight: FontWeight.w900, fontSize: 15),
                            ),
                          ),
                        ],
                      ),
                      Text(
                        'Bill #$bill · $selectedOutletName',
                        style: const TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 12),
                      if (snapshot.connectionState == ConnectionState.waiting)
                        const Expanded(
                            child: Center(child: CircularProgressIndicator()))
                      else if (snapshot.hasError)
                        const Expanded(
                            child: Center(
                                child:
                                    EmptyText('Unable to load item details.')))
                      else if (items.isEmpty)
                        const Expanded(
                            child: Center(
                                child: EmptyText(
                                    'No item details returned by POS.')))
                      else
                        Expanded(
                          child: ListView.separated(
                            itemCount: items.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (_, index) {
                              final item = items[index];
                              final name = stringValue(
                                field(item, [
                                  'i_Name',
                                  'item_name',
                                  'itemName',
                                  'name'
                                ]),
                                'Item',
                              );
                              final qty = field(
                                  item,
                                  ['qty', 'quantity', 'qtyValue', 'qty_value'],
                                  0);
                              final rate = field(item, ['rate_fk', 'rate'], 0);
                              final amount = field(item,
                                  ['amount', 'item_amount', 'itemAmount'], 0);
                              return Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 9),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(name,
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w800,
                                                  fontSize: 15)),
                                          const SizedBox(height: 3),
                                          Text('Qty $qty × ${money(rate)}',
                                              style: const TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 12)),
                                        ],
                                      ),
                                    ),
                                    Text(money(amount),
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w900,
                                            fontSize: 15)),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      if (detail != null) ...[
                        const Divider(),
                        _dialogTotal(
                            'Net Sale',
                            field(detail, ['netSale', 'net_sale', 'netTotal'],
                                0)),
                        _dialogTotal(
                            'Gross Sale',
                            field(
                                detail,
                                [
                                  'grossSale',
                                  'gross_sale',
                                  'bill_amount',
                                  'grossTotal'
                                ],
                                0)),
                        _dialogTotal(
                            'Pending Amount',
                            field(
                                detail,
                                [
                                  'pendingAmt',
                                  'pendingAmount',
                                  'unSatteledAmount'
                                ],
                                0)),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
    autoClose = Timer(const Duration(seconds: 20), () {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
    await dialogFuture;
    autoClose?.cancel();
  }

  Widget _dialogTotal(String title, dynamic value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(
                child: Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w700))),
            Text(money(value),
                style: const TextStyle(fontWeight: FontWeight.w900)),
          ],
        ),
      );

  Widget _countCard(String title, int value, IconData icon) => Expanded(
        child: Container(
          constraints: const BoxConstraints(minHeight: 50),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF111633),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: .08)),
          ),
          child: Row(
            children: [
              Icon(icon, size: 17),
              const SizedBox(width: 5),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(title,
                      maxLines: 1,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(width: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text('$value',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w900)),
              ),
            ],
          ),
        ),
      );

  Widget _metricHeader(
          String title, dynamic value, IconData icon, Color accent) =>
      Expanded(
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 11),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [accent.withValues(alpha: .22), const Color(0xFF111633)],
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: accent.withValues(alpha: .38)),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: accent.withValues(alpha: .16),
                    shape: BoxShape.circle),
                child: Icon(icon, size: 18, color: accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title.toUpperCase(),
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            letterSpacing: .8)),
                    const SizedBox(height: 3),
                    FittedBox(
                      alignment: Alignment.centerLeft,
                      fit: BoxFit.scaleDown,
                      child: Text(money(value),
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w900)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final rows = selectedLive;
    // All financial cards in this page are calculated only from successful
    // LiveTableItem/Sale responses. Dashboard/Sale is never a financial
    // fallback for Live Tables.
    final gross = _metric(
      ['grossSale', 'gross_sale', 'grossTotal', 'gross_total', 'grossAmount', 'gross_amount', 'totalGross', 'total_gross'],
      ['grossTotal', 'grossSale', 'gross_sale', 'grossAmount', 'gross_amount', 'totalGross', 'total_gross'],
    );
    final net = _metric(
      ['netSale', 'net_sale', 'netTotal', 'net_total', 'netAmount', 'net_amount', 'totalNet', 'total_net'],
      ['netTotal', 'netSale', 'net_sale', 'netAmount', 'net_amount', 'totalNet', 'total_net'],
    );
    final pending = _metric(
      ['pendingAmt', 'pendingAmount', 'pending_amt', 'unSatteledAmount'],
      [
        'unSatteledAmount',
        'unSettledAmount',
        'unsettledAmount',
        'pendingAmount',
        'pendingAmt',
        'pending_amt',
        'settlementPending',
        'pendingSettlement'
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset('assets/app_icon.png', width: 34, height: 34),
            const SizedBox(width: 10),
            const Text(appTitle, style: TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
        actions: [
          IconButton(
              onPressed: loading ? null : () => load(resetOutlet: true),
              icon: const Icon(Icons.refresh)),
          IconButton(
              onPressed: widget.onLogout, icon: const Icon(Icons.logout)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => load(resetOutlet: true),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            Text('REAL-TIME POS',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.secondary,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5)),
            const SizedBox(height: 3),
            Text(selectedOutletName,
                style:
                    const TextStyle(fontSize: 27, fontWeight: FontWeight.w900)),
            const Text('Auto refresh every 60 seconds',
                style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF111633),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withValues(alpha: .10)),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: selectedOutletId == '0' ||
                          outlets.any((o) => outletIdOf(o) == selectedOutletId)
                      ? selectedOutletId
                      : '0',
                  isExpanded: true,
                  dropdownColor: const Color(0xFF151A3B),
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  items: [
                    const DropdownMenuItem<String>(
                      value: '0',
                      child: Text('Select Outlet · All Outlets',
                          style: TextStyle(fontWeight: FontWeight.w800)),
                    ),
                    ...outlets.map((o) => DropdownMenuItem<String>(
                          value: outletIdOf(o),
                          child: Text(outletNameOf(o),
                              style:
                                  const TextStyle(fontWeight: FontWeight.w800)),
                        )),
                  ],
                  onChanged: (value) async {
                    if (value == null || value == selectedOutletId) return;
                    setState(() => selectedOutletId = value);
                    await load();
                  },
                ),
              ),
            ),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 760;
                final cards = [
                  _metricHeader('Gross Sale', gross, Icons.payments_outlined,
                      Colors.orangeAccent),
                  _metricHeader('Net Sale', net, Icons.trending_up_rounded,
                      Colors.cyanAccent),
                  _metricHeader('Pending', pending,
                      Icons.pending_actions_rounded, Colors.amberAccent),
                ];
                if (narrow) {
                  return Column(
                    children: [
                      Row(children: [
                        cards[0],
                        const SizedBox(width: 8),
                        cards[1]
                      ]),
                      const SizedBox(height: 8),
                      Row(children: [cards[2], const Spacer()]),
                    ],
                  );
                }
                return Row(children: [
                  cards[0],
                  const SizedBox(width: 8),
                  cards[1],
                  const SizedBox(width: 8),
                  cards[2]
                ]);
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _countCard('All', liveTableCandidates.length, Icons.grid_view_rounded),
                const SizedBox(width: 8),
                _countCard('Running', runningCount, Icons.play_circle_outline),
                const SizedBox(width: 8),
                _countCard(
                    'Completed', completedCount, Icons.check_circle_outline),
              ],
            ),
            const SizedBox(height: 14),
            if (rows.isEmpty)
              const Card(
                  child: EmptyText('No live tables available right now.'))
            else
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount:
                      MediaQuery.sizeOf(context).width > 800 ? 4 : 2,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 1.05,
                ),
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final row = rows[index];
                  final status = stringValue(field(
                          row, ['bill_status', 'billStatus', 'status'], '0'))
                      .trim()
                      .toLowerCase();
                  final running =
                      status == '0' || status == 'running' || status == 'open';
                  return InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => openTable(row),
                    child: Card(
                      color: running
                          ? const Color(0xFF4A4320)
                          : const Color(0xFF3D2230),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                    child: Text('Table No: ${tableDisplayNameOf(row)}',
                                        style: const TextStyle(
                                            fontSize: 17,
                                            fontWeight: FontWeight.w900))),
                                Icon(
                                    running ? Icons.circle : Icons.check_circle,
                                    size: 12,
                                    color: running
                                        ? Colors.amberAccent
                                        : Colors.pinkAccent),
                              ],
                            ),
                            const SizedBox(height: 6),
                            if (selectedOutletId == '0')
                              Text(outletNameOf(row),
                                  style: const TextStyle(
                                      color: Colors.white70,
                                      fontWeight: FontWeight.w700)),
                            Text(running ? 'RUNNING' : 'COMPLETED',
                                style: TextStyle(
                                    color: running
                                        ? Colors.amberAccent
                                        : Colors.pinkAccent,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 12)),
                            const Spacer(),
                            Text(
                                'Bill #${billNoOf(row).isEmpty ? '—' : billNoOf(row)}',
                                style: const TextStyle(color: Colors.white70)),
                            Text(
                                '${field(row, ['cover', 'pax'], 0)} Pax · ${field(row, [
                                      'bill_time',
                                      'billTime',
                                      'time'
                                    ], '')}',
                                style: const TextStyle(color: Colors.white70)),
                            const SizedBox(height: 5),
                            Text(money(billAmountOf(row)),
                                style: const TextStyle(
                                    fontSize: 19, fontWeight: FontWeight.w900)),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class ReportsPage extends StatefulWidget {
  final ApiService api;
  final String outletId;
  final String outletName;
  const ReportsPage(
      {super.key,
      required this.api,
      required this.outletId,
      required this.outletName});

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  int period = 0;
  bool loading = false;
  String processingText = '';
  Timer? timer;
  List<ChartPoint> points = [];
  num totalSales = 0;
  Map<String, num> metrics = {};
  Map<String, dynamic> previousWeekData = {};
  int requestId = 0;

  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(seconds: 45), (_) => load());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    if (loading) return;
    final request = ++requestId;
    if (mounted) {
      setState(() {
        loading = true;
        processingText = 'Syncing ${_periodName()}…';
      });
    }
    try {
      final ranges = _ranges();
      final results = <ChartPoint>[];
      const concurrency = 3;
      for (var offset = 0; offset < ranges.length; offset += concurrency) {
        final batch = ranges.skip(offset).take(concurrency).toList();
        if (!mounted || request != requestId) return;
        setState(() => processingText =
            'Syncing ${_periodName()} · ${offset + 1}-${offset + batch.length}/${ranges.length}');
        final batchResults = await Future.wait(batch.map(_fetchRange));
        if (!mounted || request != requestId) return;
        results.addAll(batchResults);
        setState(() {
          points = List<ChartPoint>.from(results);
          totalSales = results.fold<num>(0, (sum, p) => sum + p.value);
        });
      }

      setState(() => processingText = 'Finalizing ${_periodName()}…');
      final full = _fullRange();
      final cacheKey =
          'report_${period}_${widget.outletId}_${apiDate(full.$1)}_${apiDate(full.$2)}';
      try {
        final reportOutletId = normalizedId(widget.outletId).isEmpty
            ? '0'
            : normalizedId(widget.outletId);
        final json = await widget.api.dashboard(
          apiDate(full.$1),
          apiDate(full.$2),
          reportOutletId,
          useOutletFilter: reportOutletId != '0',
        );
        final response = responseMap(json);
        Map<String, dynamic> previousResponse = {};
        try {
          final previousFrom = full.$1.subtract(const Duration(days: 7));
          final previousTo = full.$2.subtract(const Duration(days: 7));
          final previousJson = await widget.api.dashboard(
            apiDate(previousFrom),
            apiDate(previousTo),
            reportOutletId,
            useOutletFilter: reportOutletId != '0',
          );
          previousResponse = responseMap(previousJson);
        } catch (_) {}
        final rows = rowsFromResponse(
          response,
          ['saleSummary', 'salesummary', 'salesSummary', 'summary', 'sale'],
          ['grosstotal', 'grosssale', 'nettotal', 'netsale', 'ordertotal'],
        );
        final selected = summaryForOutlet(
        rows,
        reportOutletId,
        outletName: widget.outletName,
      );
        final nextMetrics = <String, num>{
          'Gross Sale': _sum(selected, 'grossTotal'),
          'Net Sale': _sum(selected, 'netTotal'),
          'Tax': _sum(selected, 'taxTotal'),
          'Discount': _sum(selected, 'discountTotal'),
          'Orders': _sum(selected, 'orderTotal'),
          'Covers': _sum(selected, 'coverTotal'),
          'Unsettled': _sum(selected, 'unSatteledAmount'),
          'Complimentary': _sum(selected, 'complementary'),
        };
        await OfflineStore.save(cacheKey, {
          'points':
              results.map((p) => {'label': p.label, 'value': p.value}).toList(),
          'totalSales': totalSales,
          'metrics': nextMetrics,
        });
        if (mounted && request == requestId) {
          setState(() {
            metrics = nextMetrics;
            previousWeekData = previousResponse;
            processingText = '';
          });
        }
      } catch (_) {
        final cached = await OfflineStore.read(cacheKey);
        if (cached != null && mounted && request == requestId) {
          final cachedPoints = asRows(cached['points']);
          setState(() {
            points = cachedPoints
                .map((p) => ChartPoint(
                      stringValue(p['label']),
                      number(p['value']),
                    ))
                .toList();
            totalSales = number(cached['totalSales']);
            final rawMetrics = cached['metrics'];
            metrics = rawMetrics is Map
                ? rawMetrics.map((k, v) => MapEntry(k.toString(), number(v)))
                : metrics;
            processingText = 'Offline · showing last synced analytics';
          });
        } else if (mounted && request == requestId) {
          setState(
              () => processingText = 'Offline · showing last available data');
        }
      }
    } catch (_) {
      if (mounted && request == requestId) {
        setState(
            () => processingText = 'Offline · showing last available data');
      }
    } finally {
      if (mounted && request == requestId) setState(() => loading = false);
    }
  }

  String _periodName() =>
      const ['Daily', 'Weekly', 'Monthly', 'Yearly'][period];

  num _sum(List<Map<String, dynamic>> rows, String key) => rows.fold<num>(
        0,
        (sum, row) =>
            sum +
            number(field(row, [key, key[0].toUpperCase() + key.substring(1)])),
      );

  (DateTime, DateTime) _fullRange() {
    final now = DateTime.now();
    switch (period) {
      case 0:
        return (DateTime(now.year, now.month, now.day - 6), now);
      case 1:
        return (DateTime(now.year, now.month, now.day - 55), now);
      case 2:
        return (DateTime(now.year, now.month - 11, 1), now);
      default:
        return (DateTime(now.year - 4, 1, 1), now);
    }
  }

  List<({String label, DateTime from, DateTime to})> _ranges() {
    final now = DateTime.now();
    final list = <({String label, DateTime from, DateTime to})>[];
    if (period == 0) {
      for (int i = 6; i >= 0; i--) {
        final d = DateTime(now.year, now.month, now.day - i);
        list.add((label: DateFormat('EEE').format(d), from: d, to: d));
      }
    } else if (period == 1) {
      for (int i = 7; i >= 0; i--) {
        final end = DateTime(now.year, now.month, now.day - (i * 7));
        final start = DateTime(end.year, end.month, end.day - 6);
        list.add((label: 'W${8 - i}', from: start, to: end));
      }
    } else if (period == 2) {
      for (int i = 11; i >= 0; i--) {
        final d = DateTime(now.year, now.month - i, 1);
        final end = DateTime(d.year, d.month + 1, 0);
        list.add((label: DateFormat('MMM').format(d), from: d, to: end));
      }
    } else {
      for (int i = 4; i >= 0; i--) {
        final year = now.year - i;
        list.add((
          label: '$year',
          from: DateTime(year, 1, 1),
          to: DateTime(year, 12, 31)
        ));
      }
    }
    return list;
  }

  Future<ChartPoint> _fetchRange(
      ({String label, DateTime from, DateTime to}) range) async {
    try {
      final reportOutletId = normalizedId(widget.outletId).isEmpty
          ? '0'
          : normalizedId(widget.outletId);
      final json = await widget.api.dashboard(
        apiDate(range.from),
        apiDate(range.to),
        reportOutletId,
        useOutletFilter: reportOutletId != '0',
      );
      final response = responseMap(json);
      final rows = rowsFromResponse(
        response,
        ['saleSummary', 'salesummary', 'salesSummary', 'summary', 'sale'],
        ['grosstotal', 'grosssale', 'nettotal', 'netsale', 'ordertotal'],
      );
      final selected = summaryForOutlet(
        rows,
        reportOutletId,
        outletName: widget.outletName,
      );
      if (selected.isNotEmpty) {
        return ChartPoint(range.label, _sum(selected, 'grossTotal'));
      }
      return ChartPoint(range.label, 0);
    } catch (_) {
      return ChartPoint(range.label, 0);
    }
  }


  @override
  Widget build(BuildContext context) {
    const labels = ['Daily', 'Weekly', 'Monthly', 'Yearly'];
    final max = points.fold<num>(0, (m, p) => p.value > m ? p.value : m);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports & Analytics',
            style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
              onPressed: loading ? null : load, icon: const Icon(Icons.refresh))
        ],
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Row(children: [
                  for (int i = 0; i < labels.length; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: ChoiceChip(
                          label: SizedBox(
                              width: double.infinity,
                              child: Center(child: Text(labels[i]))),
                          selected: period == i,
                          onSelected: (_) {
                            if (period == i || loading) return;
                            setState(() => period = i);
                            unawaited(load());
                          },
                        ),
                      ),
                    ),
                ]),
              ),
            ),
            if (loading || processingText.isNotEmpty) ...[
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  child: Row(
                    children: [
                      const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          processingText.isEmpty
                              ? 'Processing…'
                              : processingText,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 14),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          'TOTAL SALES · ${widget.outletId == '0' ? 'ALL OUTLETS' : widget.outletName.toUpperCase()}',
                          style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 10,
                              letterSpacing: 1.2)),
                      const SizedBox(height: 8),
                      Text(money(totalSales),
                          style: const TextStyle(
                              fontSize: 35, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 5),
                      Text('Live from POS · auto refresh',
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.secondary)),
                    ]),
              ),
            ),
            const SizedBox(height: 14),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 20),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('SALES',
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.secondary,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.5)),
                      const SizedBox(height: 4),
                      const Text('Performance',
                          style: TextStyle(
                              fontSize: 21, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 22),
                      SizedBox(
                        height: 245,
                        child: points.isEmpty
                            ? const Center(child: CircularProgressIndicator())
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: points.map((p) {
                                  final height = max <= 0
                                      ? 18.0
                                      : 18 + (p.value / max) * 145;
                                  return Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 3),
                                      child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.end,
                                          children: [
                                            Text(money(p.value),
                                                textAlign: TextAlign.center,
                                                style: const TextStyle(
                                                    fontSize: 9,
                                                    fontWeight:
                                                        FontWeight.w800)),
                                            const SizedBox(height: 5),
                                            Container(
                                              height: height.toDouble(),
                                              decoration: const BoxDecoration(
                                                gradient: LinearGradient(
                                                    begin: Alignment.topCenter,
                                                    end: Alignment.bottomCenter,
                                                    colors: [
                                                      Color(0xFF5FD1DD),
                                                      Color(0xFF6C45F5)
                                                    ]),
                                                borderRadius:
                                                    BorderRadius.vertical(
                                                        top:
                                                            Radius.circular(8)),
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(p.label,
                                                style: const TextStyle(
                                                    color: Colors.white70,
                                                    fontSize: 9)),
                                          ]),
                                    ),
                                  );
                                }).toList(),
                              ),
                      ),
                    ]),
              ),
            ),
            const SizedBox(height: 14),
            const SizedBox(height: 14),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: MediaQuery.sizeOf(context).width > 700 ? 4 : 2,
              childAspectRatio: 1.7,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              children: metrics.entries
                  .map((e) => Card(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(e.key,
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 12)),
                                const Spacer(),
                                Text(
                                    e.key == 'Orders' || e.key == 'Covers'
                                        ? e.value.toStringAsFixed(0)
                                        : money(e.value),
                                    style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w900)),
                              ]),
                        ),
                      ))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class ChartPoint {
  final String label;
  final num value;
  const ChartPoint(this.label, this.value);
}

extension FirstOrNullExtension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
