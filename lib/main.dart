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
const refreshSeconds = 30;

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
  final String rawBody;
  final dynamic decoded;
  const _HttpStatusException(
    this.statusCode,
    this.message, {
    this.rawBody = '',
    this.decoded,
  });
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
    bool retryTransient = true,
    bool exactApiKeyFieldOnly = false,
    bool loginGatewayHeaders = false,
    bool preserveHttpStatus = false,
    int retryAttempts = 3,
  }) async {
    final cleanKey = key.trim();
    if (cleanKey.isEmpty) {
      throw Exception('API key is missing. Please activate this device once.');
    }

    Object? lastError;
    final maxAttempts = retryTransient ? retryAttempts.clamp(1, 3).toInt() : 1;

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
          if (loginGatewayHeaders) 'X-API-Key': cleanKey,
          if (!loginGatewayHeaders && !legacyLoginHeaders && !exactApiKeyFieldOnly)
            'Key': cleanKey,
          if (!loginGatewayHeaders && !legacyLoginHeaders && !exactApiKeyFieldOnly)
            'X-API-Key': cleanKey,
        });
        request.fields.addAll({
          ...fields,
          if (includeApiKeyFields) 'Keys': cleanKey,
          if (includeApiKeyFields && !legacyLoginHeaders && !exactApiKeyFieldOnly) 'key': cleanKey,
          if (includeApiKeyFields && !legacyLoginHeaders && !exactApiKeyFieldOnly) 'APIKey': cleanKey,
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
            rawBody: response.body,
            decoded: decoded,
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
          if (!retryableStatus) {
            break;
          }
        }

        final retryable = e is TimeoutException ||
            e is SocketException ||
            e is http.ClientException ||
            (e is _HttpStatusException &&
                (e.statusCode == 408 ||
                    e.statusCode == 429 ||
                    e.statusCode >= 500));

        if (!retryable || attempt == maxAttempts - 1) {
          break;
        }

        // 400/401/403/422 never reach this branch. Network/5xx retries use
        // bounded exponential backoff with tiny jitter.
        final backoffMs = 400 * (1 << attempt);
        final jitterMs = (attempt * 113) % 180;
        await Future<void>.delayed(
          Duration(milliseconds: backoffMs + jitterMs),
        );
      } finally {
        if (freshConnection) {
          final client = requestClient;
          if (client != null) {
            client.close();
          }
        }
      }
    }

    if (lastError is _ApiKeyRejected) {
      throw Exception(
        'API key rejected by server. Please check the key in Change API Key.',
      );
    }

    if (lastError is _HttpStatusException) {
      if (preserveHttpStatus) {
        throw lastError;
      }
      final error = lastError;
      if (error.statusCode == 401 || error.statusCode == 403) {
        final serverText = error.message.toLowerCase();
        if (serverText.contains('api key') ||
            serverText.contains('api-key') ||
            serverText.contains('key rejected') ||
            serverText.contains('invalid key')) {
          throw Exception('API key rejected. Please check the API key.');
        }
        throw Exception('Authentication failed. Please sign in again.');
      }
      if (error.statusCode == 408) {
        throw Exception(
          'Connection is too slow. Please check your internet connection and try again.',
        );
      }
      if (error.statusCode == 429) {
        throw Exception(
          'The server is busy with too many requests. Please try again shortly.',
        );
      }
      if (error.statusCode >= 500) {
        throw Exception(
          'Suvidha POS server is temporarily unavailable. Please try again shortly.',
        );
      }
      if (error.statusCode == 400 || error.statusCode == 422) {
        throw Exception(
          error.message.isNotEmpty
              ? error.message
              : 'The request was not accepted. Please check the entered details.',
        );
      }
      throw Exception(
        error.message.isNotEmpty
            ? error.message
            : 'The request could not be completed. Please try again.',
      );
    }

    if (lastError is TimeoutException) {
      throw Exception(
        'Connection is too slow. Please check your internet connection and try again.',
      );
    }
    if (lastError is SocketException) {
      final lower = lastError.toString().toLowerCase();
      if (lower.contains('failed host lookup') ||
          lower.contains('network is unreachable') ||
          lower.contains('no address associated')) {
        throw Exception(
          'No internet connection, or the Suvidha POS server cannot be reached. Please check your network and try again.',
        );
      }
      throw Exception(
        'Unable to connect to the Suvidha POS server. Please check your internet connection and try again.',
      );
    }
    if (lastError is HandshakeException) {
      throw Exception(
        'Secure connection to the Suvidha POS server could not be established. Please check your network and try again.',
      );
    }
    if (lastError is http.ClientException) {
      throw Exception(
        'Unable to reach the Suvidha POS server. Please check your internet connection and try again.',
      );
    }
    final message = lastError?.toString() ?? 'Request failed';
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
    if (decoded is! Map) {
      return '';
    }
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
    if (json.isEmpty) {
      return true;
    }
    for (final key in const ['response', 'data', 'result', 'payload']) {
      if (json.containsKey(key) && json[key] == null) {
        return true;
      }
    }
    return false;
  }

  Future<Map<String, dynamic>> _loginRequest(
    String cleanId,
    String cleanPassword, {
    required bool gatewayHeaderProfile,
  }) {
    // Profile A (default) intentionally matches the request shape that was
    // already working in production before the deep refactor:
    //   headers: Keys
    //   multipart fields: LoginID, Password, Keys
    // Some gateway deployments instead expect the smoke-test profile:
    //   headers: Keys + X-API-Key
    //   multipart fields: LoginID, Password
    // Login() uses A first and only tries B after a generic protocol rejection.
    return post(
      '/DashboardLogin',
      {
        'LoginID': cleanId,
        'Password': cleanPassword,
      },
      allowEmptyPayload: true,
      freshConnection: true,
      includeApiKeyFields: !gatewayHeaderProfile,
      requestTimeout: const Duration(seconds: 10),
      retryTransient: true,
      exactApiKeyFieldOnly: !gatewayHeaderProfile,
      loginGatewayHeaders: gatewayHeaderProfile,
      preserveHttpStatus: true,
      retryAttempts: gatewayHeaderProfile ? 1 : 2,
    );
  }

  bool _shouldTryAlternateLoginProfile(_HttpStatusException error) {
    final text = '${error.message} ${error.rawBody}'.toLowerCase();

    // Never duplicate a request when the server has already identified a real
    // credential or API-key problem. The fallback is only for request-shape /
    // gateway compatibility failures.
    if (_containsCredentialFailure(text) || _containsApiKeyError(text)) {
      return false;
    }

    if (error.statusCode == 400 ||
        error.statusCode == 415 ||
        error.statusCode == 422) {
      return true;
    }

    // 401/403 can mean credentials, so only retry those if the server wording
    // points to a missing/unsupported key/header/request format.
    if (error.statusCode == 401 || error.statusCode == 403) {
      return text.contains('missing') ||
          text.contains('header') ||
          text.contains('key required') ||
          text.contains('api key required') ||
          text.contains('unsupported') ||
          text.contains('request format');
    }
    return false;
  }

  Future<void> login(String id, String password) async {
    final cleanId = id.trim();
    final cleanPassword = password;
    if (cleanId.isEmpty || cleanPassword.isEmpty) {
      throw Exception('Please enter both User ID and Password.');
    }

    try {
      Map<String, dynamic> json;
      try {
        // First use the exact production-compatible request shape that the app
        // used before v1.0.7. This restores the multipart `Keys` field that the
        // live server may require.
        json = await _loginRequest(
          cleanId,
          cleanPassword,
          gatewayHeaderProfile: false,
        );
      } on _HttpStatusException catch (primaryError) {
        if (!_shouldTryAlternateLoginProfile(primaryError)) {
          rethrow;
        }

        try {
          // One controlled compatibility attempt for gateway versions that use
          // the header-only login contract documented by the smoke test.
          json = await _loginRequest(
            cleanId,
            cleanPassword,
            gatewayHeaderProfile: true,
          );
        } on _HttpStatusException catch (fallbackError) {
          final fallbackText =
              '${fallbackError.message} ${fallbackError.rawBody}'.toLowerCase();
          if (_containsCredentialFailure(fallbackText) ||
              _containsApiKeyError(fallbackText)) {
            throw fallbackError;
          }
          // The original response is usually the best representation of the
          // production endpoint. Preserve it if both protocol profiles fail.
          throw primaryError;
        }
      }

      final response = responseMap(json);
      final status = field(response, ['status', 'success', 'isSuccess', 'ok']) ??
          field(json, ['status', 'success', 'isSuccess', 'ok']);
      final message = stringValue(
        field(response, [
              'message', 'msg', 'error', 'reason', 'errorMessage',
              'error_message', 'statusMessage'
            ]) ??
            field(json, [
              'message', 'msg', 'error', 'reason', 'errorMessage',
              'error_message', 'statusMessage'
            ]),
      ).trim();
      final combinedText =
          '${message.toLowerCase()} ${jsonEncode(json).toLowerCase()}';

      if (_containsApiKeyError(combinedText)) {
        throw Exception(
          'API key rejected. Please verify the API key in Change API Key.',
        );
      }
      if (status != null && !success(status)) {
        throw Exception(_friendlyLoginReason(json, response, message));
      }
      if (status == null && _containsCredentialFailure(combinedText)) {
        throw Exception(_friendlyLoginReason(json, response, message));
      }
    } on _HttpStatusException catch (e) {
      final text = '${e.message} ${e.rawBody}'.toLowerCase();
      if (_containsApiKeyError(text)) {
        throw Exception(
          'API key rejected. Please verify the API key in Change API Key.',
        );
      }
      if (e.statusCode == 408) {
        throw Exception(
          'Login timed out. Your internet connection or the Suvidha POS server is responding too slowly. Please try again.',
        );
      }
      if (e.statusCode == 429) {
        throw Exception(
          'Too many login attempts. Please wait a few seconds and try again.',
        );
      }
      if (e.statusCode >= 500) {
        throw Exception(
          'Suvidha POS server is temporarily unavailable. Please try again shortly.',
        );
      }
      if (e.statusCode == 400 ||
          e.statusCode == 401 ||
          e.statusCode == 403 ||
          e.statusCode == 415 ||
          e.statusCode == 422) {
        final decoded = e.decoded is Map
            ? Map<String, dynamic>.from(e.decoded as Map)
            : <String, dynamic>{};
        final response = responseMap(decoded);
        throw Exception(_friendlyLoginReason(decoded, response, e.message));
      }
      rethrow;
    }
  }

  bool _containsApiKeyError(String text) {
    final lower = text.toLowerCase();
    return lower.contains('key is invalid') ||
        lower.contains('invalid api key') ||
        lower.contains('api key rejected') ||
        lower.contains('api key was rejected') ||
        lower.contains('invalid key') ||
        lower.contains('key rejected');
  }

  bool _containsCredentialFailure(String text) {
    final lower = text.toLowerCase();
    return lower.contains('login failed') ||
        lower.contains('invalid credential') ||
        lower.contains('wrong password') ||
        lower.contains('incorrect password') ||
        lower.contains('invalid password') ||
        lower.contains('password is wrong') ||
        lower.contains('password not match') ||
        lower.contains('password mismatch') ||
        lower.contains('invalid pwd') ||
        lower.contains('wrong pwd') ||
        lower.contains('user not found') ||
        lower.contains('user not available') ||
        lower.contains('invalid user') ||
        lower.contains('invalid username') ||
        lower.contains('invalid login id') ||
        lower.contains('invalid userid') ||
        lower.contains('username not found') ||
        lower.contains('login id not found') ||
        lower.contains('userid not found') ||
        lower.contains('user id not found') ||
        lower.contains('user does not exist') ||
        lower.contains("user doesn't exist") ||
        lower.contains('incorrect username') ||
        lower.contains('incorrect user id') ||
        lower.contains('wrong user id');
  }

  String _friendlyLoginReason(
    Map<String, dynamic> json,
    Map<String, dynamic> response,
    String serverMessage,
  ) {
    final text = '${serverMessage.toLowerCase()} ${jsonEncode(json).toLowerCase()} ${jsonEncode(response).toLowerCase()}';
    if (_containsApiKeyError(text)) {
      return 'API key rejected. Please verify the API key in Change API Key.';
    }
    if (text.contains('wrong password') ||
        text.contains('incorrect password') ||
        text.contains('invalid password') ||
        text.contains('password is wrong') ||
        text.contains('password incorrect') ||
        text.contains('password not match') ||
        text.contains('password mismatch') ||
        text.contains('invalid pwd') ||
        text.contains('wrong pwd')) {
      return 'Password is wrong. Please check your password and try again.';
    }
    if (text.contains('user not found') ||
        text.contains('user not available') ||
        text.contains('invalid user') ||
        text.contains('invalid username') ||
        text.contains('invalid login id') ||
        text.contains('invalid userid') ||
        text.contains('username not found') ||
        text.contains('login id not found') ||
        text.contains('userid not found') ||
        text.contains('user id not found') ||
        text.contains('user does not exist') ||
        text.contains("user doesn't exist") ||
        text.contains('incorrect username') ||
        text.contains('incorrect user id') ||
        text.contains('wrong user id')) {
      return 'User ID is wrong. Please check your User ID and try again.';
    }
    if (_containsCredentialFailure(text) ||
        text.contains('unauthorized') ||
        text.contains('authentication failed') ||
        text.contains('credentials')) {
      return 'User ID or Password is incorrect. Please check both and try again.';
    }
    if (serverMessage.trim().isNotEmpty &&
        !serverMessage.toLowerCase().contains('bad request') &&
        !serverMessage.toLowerCase().contains('server error')) {
      return serverMessage.trim();
    }
    return 'Login request was rejected by the server. Please check your User ID, Password and API key, then try again.';
  }

  Future<Map<String, dynamic>> dashboard(
    String from,
    String to,
  ) {
    return post('/Dashboard/Sale', {
      'from_date': from,
      'to_date': to,
      // Permanent source-of-truth rule: Dashboard/Sale is always requested as
      // ids=0. A selected outlet is filtered locally from explicitly tagged
      // outlet rows, avoiding partial outlet-scoped responses.
      'ids': '0',
    });
  }

  /// Live Tables are backed only by the POS LiveTableItem/Sale endpoint.
  /// bill_no=0 returns the current live-table dataset; an exact bill number is
  /// used only when opening a table detail. Dashboard/Sale is not part of this
  /// flow, avoiding the old discovery + N-detail request waterfall.
  Future<Map<String, dynamic>> liveTable(String outletId, String billNo) {
    return post('/LiveTableItem/Sale', {
      'outlet_id': outletId,
      'bill_no': billNo,
    });
  }

  Future<Map<String, dynamic>> topSellingItems() {
    return post(
      '/Tablet/ListofItems/POS',
      const {'billType': 'k'},
      allowEmptyPayload: true,
      requestTimeout: const Duration(seconds: 15),
      retryTransient: true,
    );
  }
}

Map<String, dynamic> asMap(dynamic value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return <String, dynamic>{};
}

Map<String, dynamic> responseMap(Map<String, dynamic> json) {
  for (final key in ['response', 'data', 'result', 'payload']) {
    final response = asMap(field(json, [key]));
    if (response.isNotEmpty) {
      return response;
    }
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
    if (rows.isNotEmpty) {
      return rows;
    }
  }

  bool looksLikeRow(Map<String, dynamic> row) {
    final lowered = row.keys.map((e) => e.toLowerCase()).toSet();
    return rowHints.any(lowered.contains);
  }

  if (looksLikeRow(response)) {
    return <Map<String, dynamic>>[response];
  }

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
        if (item is Map || item is List) {
          walk(item);
        }
      }
    } else if (value is Map) {
      for (final item in value.values) {
        if (item is Map || item is List) {
          walk(item);
        }
      }
    }
  }

  walk(response);
  return found;
}

dynamic field(Map<String, dynamic> row, List<String> names,
    [dynamic fallback]) {
  for (final name in names) {
    if (row.containsKey(name) && row[name] != null) {
      return row[name];
    }
  }
  final lower = <String, dynamic>{};
  row.forEach((key, value) => lower[key.toLowerCase()] = value);
  for (final name in names) {
    final value = lower[name.toLowerCase()];
    if (value != null) {
      return value;
    }
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
  if (value == null) {
    return 0;
  }
  if (value is num) {
    return value;
  }
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
      if (!await file.exists()) {
        return null;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return null;
      }
      final data = decoded['data'];
      return data is Map ? Map<String, dynamic>.from(data) : null;
    } catch (_) {
      return null;
    }
  }
}

String normalizedId(dynamic value) {
  final text = stringValue(value).trim();
  if (text.isEmpty) {
    return '';
  }
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

/// Strict outlet identity for endpoint rows that can also contain generic
/// `id`/`name` fields for bills, tables or items. Use this while scoping Live
/// Tables so an internal row ID can never be mistaken for an outlet ID.
String explicitOutletIdOf(Map<String, dynamic> row) => normalizedId(
      field(row, [
        'outletId', 'outletID', 'OutletID', 'outlet_id', 'outletid', 'Outlet_Id',
        'outlet_Id', 'outletID_fk', 'outletIdFk', 'outlet_id_fk',
        'o_Id', 'o_id', 'oID', 'outletCode', 'outlet_code',
        'branchId', 'branch_id', 'branchID', 'branchCode', 'branch_code',
        'outletNo', 'outlet_no',
      ]),
    );

String explicitOutletNameOf(Map<String, dynamic> row) => stringValue(
      field(row, [
        'outletName', 'outlet_name', 'OutletName', 'Outlet_Name',
        'outlet', 'outletDesc', 'outlet_desc', 'branchName', 'branch_name',
        'branch',
      ]),
    ).trim();

bool rowMatchesOutlet(
  Map<String, dynamic> row,
  String outletId, {
  String outletName = '',
}) {
  final wantedId = normalizedId(outletId);
  if (wantedId.isEmpty || wantedId == '0') {
    return true;
  }
  final rowId = outletIdOf(row);
  if (rowId == wantedId) {
    return true;
  }
  final wantedName = outletName.trim().toLowerCase();
  if (wantedName.isEmpty || wantedName == 'all outlets') {
    return false;
  }
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
        'TableNo', 'Table_No', 'table_no_fk', 'tableNoFk',
        'tableId', 'table_id', 't_Id', 't_id', 't_no', 'tNo',
      ]),
      '—',
    );

bool _validTableNameCandidate(String value) {
  final clean = value.trim();
  if (clean.isEmpty || clean == '—' || clean == '-' || clean == '0') {
    return false;
  }
  // A bare number is treated as an internal table/master ID, not a printable
  // name. POS names such as TB1, WS1, B-2, Garden and Roof 2 remain valid.
  return !RegExp(r'^\d+(?:\.0+)?$').hasMatch(clean);
}

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
    't_NameFK', 't_name_fk', 'tNameFk', 'TNameFK',
    'tableName', 'table_name', 'TableName', 'Table_Name',
    'table_name_fk', 'tableNameFk', 'TableNameFK', 'tableNameFK',
    'table_name_fk_value', 'tblName', 'tbl_name', 'tblNameFk',
    'tbl_name_fk', 'tableTitle', 'table_title',
    'tableDesc', 'table_desc', 'tableDescription', 'table_description',
    'tableDisplayName', 'table_display_name', 'displayTableName',
    'tableLabel', 'table_label',
  ];

  final direct = stringValue(field(row, nameKeys), '').trim();
  if (_validTableNameCandidate(direct)) {
    return direct;
  }

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
    if (nested.isEmpty) {
      continue;
    }
    final name = stringValue(field(nested, nameKeys), '').trim();
    if (_validTableNameCandidate(name)) {
      return name;
    }
  }

  // A few POS versions expose the master table name directly as `table`.
  final directTable = field(row, ['table']);
  if (directTable is String &&
      _validTableNameCandidate(directTable.trim())) {
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
            key == 'tnamefk' ||
            key == 'tblname' ||
            key == 'tblnamefk' ||
            key == 'tabletitle' ||
            key == 'tablelabel') &&
        entry.value != null) {
      final candidate = entry.value.toString().trim();
      if (_validTableNameCandidate(candidate)) {
        return candidate;
      }
    }
  }

  return '—';
}

/// Resolve a printable POS table name from a complete LiveTableItem response.
/// It prefers an exact bill match, then an exact table/master ID match. This
/// handles APIs where the live bill row contains only a numeric table ID while
/// a separate nested table-master row contains the real name (TB1/WS1/etc.).
String resolveTableNameFromResponse(
  Map<String, dynamic> response, {
  String billNo = '',
  String tableNo = '',
}) {
  const nameKeys = [
    't_Name', 't_name', 'tName', 'TName', 'T_Name',
    't_NameFK', 't_name_fk', 'tNameFk', 'TNameFK',
    'tableName', 'table_name', 'TableName', 'Table_Name',
    'table_name_fk', 'tableNameFk', 'TableNameFK', 'tableNameFK',
    'tableDesc', 'table_desc', 'tableDescription', 'table_description',
    'tableDisplayName', 'table_display_name', 'displayTableName',
    'tableLabel', 'table_label', 'tblName', 'tbl_name', 'tblNameFk',
    'tbl_name_fk', 'tableTitle', 'table_title', 'table_name_fk_value',
  ];
  String best = '';
  var bestScore = -1;

  void inspect(dynamic value) {
    if (value is Map) {
      final row = Map<String, dynamic>.from(value);
      final directCandidate = stringValue(field(row, nameKeys), '').trim();
      final displayCandidate = tableDisplayNameOf(row);
      final candidate = _validTableNameCandidate(directCandidate)
          ? directCandidate
          : displayCandidate;
      if (_validTableNameCandidate(candidate)) {
        var score = 1;
        final wantedBill = billNo.trim();
        if (wantedBill.isNotEmpty && billNoOf(row).trim() == wantedBill) {
          score += 20;
        }
        final wantedTable = tableNo.trim();
        final candidateTable = stringValue(field(row, [
          'tableNo', 'tableno', 'table_No', 'table_no', 'TableNo', 'Table_No',
          'table_no_fk', 'tableNoFk', 'tableId', 'table_id', 't_Id', 't_id',
          'id',
        ]), '').trim();
        if (wantedTable.isNotEmpty &&
            wantedTable != '—' &&
            candidateTable == wantedTable) {
          score += 15;
        } else if (candidateTable.isNotEmpty &&
            candidateTable != '—' &&
            candidateTable != '-') {
          score += 2;
        }
        if (score > bestScore) {
          bestScore = score;
          best = candidate;
        }
      }
      for (final child in row.values) {
        if (child is Map || child is List) {
          inspect(child);
        }
      }
    } else if (value is List) {
      for (final child in value) {
        if (child is Map || child is List) {
          inspect(child);
        }
      }
    }
  }

  inspect(response);
  final directTable = field(response, ['table']);
  if (best.isEmpty &&
      directTable is String &&
      _validTableNameCandidate(directTable.trim())) {
    best = directTable.trim();
  }
  return best;
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
    if (matches.isNotEmpty) {
      return matches;
    }
  }
  final summaries = summaryRowsFromApi(response)
      .map(normalizeApiMetricRow)
      .toList();
  if (wanted == '0' || wanted.isEmpty) {
    return summaries;
  }
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
  if (idMatches.isNotEmpty) {
    return idMatches;
  }

  final nameMatches = rows
      .where((r) => rowMatchesOutlet(r, wanted, outletName: outletName))
      .toList();
  if (nameMatches.isNotEmpty) {
    return nameMatches;
  }

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
    if (!mounted) {
      return;
    }
    setState(() {
      activationKey = key;
      loginId = id;
      password = pass;
      loading = false;
    });
  }

  Future<void> _saveKey(String value) async {
    final cleanKey = value.trim();
    if (cleanKey.isEmpty) {
      return;
    }

    // Changing the API key starts a completely fresh authentication state.
    // Do not let credentials from the previous key survive into the new key.
    await storage.write(key: 'activationKey', value: cleanKey);
    await storage.delete(key: 'loginId');
    await storage.delete(key: 'loginPassword');
    if (!mounted) {
      return;
    }
    setState(() {
      activationKey = cleanKey;
      loginId = null;
      password = null;
    });
  }

  Future<void> _saveSession(String id, String pass) async {
    await storage.write(key: 'loginId', value: id);
    await storage.write(key: 'loginPassword', value: pass);
    if (!mounted || activationKey == null) {
      return;
    }
    setState(() {
      loginId = id;
      password = pass;
    });
  }

  Future<void> _logout() async {
    await storage.delete(key: 'loginId');
    await storage.delete(key: 'loginPassword');
    if (!mounted) {
      return;
    }
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
    if (value.isEmpty || busy) {
      return;
    }
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
    if (busy) {
      return;
    }
    if (id.isEmpty) {
      setState(() => error = 'Please enter your User ID.');
      return;
    }
    if (password.isEmpty) {
      setState(() => error = 'Please enter your Password.');
      return;
    }
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
          if (!mounted) {
            return;
          }
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
  if (rows.isNotEmpty) {
    return rows;
  }
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
  if (rows.isNotEmpty) {
    return rows;
  }
  return rowsFromResponse(
    response,
    ['saleSummary', 'salesummary', 'salesSummary', 'summary', 'sale'],
    ['gross_sale', 'grosssale', 'grosstotal', 'net_sale', 'netsale', 'nettotal'],
  );
}

/// Select one outlet from a Dashboard/Sale response without mixing scopes.
/// Production Dashboard calls use ids=0, so `responseAlreadyScoped: false`
/// accepts only rows that positively identify the requested outlet. The optional
/// scoped mode remains useful for isolated tests/legacy payloads where one
/// unlabelled summary is known to belong to the requested outlet.
List<Map<String, dynamic>> scopedDashboardSummaryRows(
  Map<String, dynamic> response,
  String outletId, {
  String outletName = '',
  bool responseAlreadyScoped = true,
}) {
  final wanted = normalizedId(outletId);
  if (wanted.isEmpty || wanted == '0') {
    return summaryRowsFromApi(response).map(normalizeApiMetricRow).toList();
  }

  final candidates = <Map<String, dynamic>>[];
  final outletRows = outletRowsFromApi(response)
      .map(normalizeApiMetricRow)
      .toList();
  candidates.addAll(outletRows.where(
    (row) => rowMatchesOutlet(row, wanted, outletName: outletName),
  ));

  final summaries = summaryRowsFromApi(response)
      .map(normalizeApiMetricRow)
      .toList();
  candidates.addAll(summaries.where(
    (row) => rowMatchesOutlet(row, wanted, outletName: outletName),
  ));

  if (candidates.isNotEmpty) {
    // One POS deployment can expose Net on an outlet row and the rest of the
    // same outlet's metrics on a second summary row. Pick the most complete
    // original row, then fill only missing/zero aliases from other rows for
    // that SAME outlet. Values are never added or mathematically derived.
    return [_mergeDashboardMetricRows(candidates, wanted, outletName)];
  }

  // Only an actual outlet-scoped request is allowed to treat one unlabelled
  // summary row as belonging to the selected outlet. An ids=0 aggregate
  // response must never relabel its combined summary as a single outlet.
  if (responseAlreadyScoped && summaries.length == 1) {
    return [
      _withOutletContext(summaries.first, wanted, outletName),
    ];
  }
  return const <Map<String, dynamic>>[];
}

Map<String, dynamic> _withOutletContext(
  Map<String, dynamic> row,
  String outletId,
  String outletName,
) {
  final copy = Map<String, dynamic>.from(row);
  if (outletIdOf(copy).isEmpty) {
    copy['outletId'] = outletId;
    copy['outlet_id'] = outletId;
  }
  if (outletName.trim().isNotEmpty && outletNameOf(copy) == 'Outlet') {
    copy['outletName'] = outletName.trim();
    copy['outlet_name'] = outletName.trim();
  }
  return copy;
}

Map<String, dynamic> _mergeDashboardMetricRows(
  Iterable<Map<String, dynamic>> rows,
  String outletId,
  String outletName,
) {
  final normalized = rows.map(normalizeApiMetricRow).toList();
  if (normalized.isEmpty) {
    return <String, dynamic>{};
  }

  const canonicalFields = [
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

  int score(Map<String, dynamic> row) {
    var total = 0;
    for (final key in canonicalFields) {
      if (field(row, [key]) != null) {
        total += number(field(row, [key])) == 0 ? 1 : 2;
      }
    }
    return total;
  }

  normalized.sort((a, b) => score(b).compareTo(score(a)));
  final result = _withOutletContext(normalized.first, outletId, outletName);
  for (final row in normalized.skip(1)) {
    for (final key in canonicalFields) {
      final current = field(result, [key]);
      final incoming = field(row, [key]);
      if (incoming != null &&
          (current == null || (number(current) == 0 && number(incoming) != 0))) {
        result[key] = incoming;
      }
    }
  }
  return result;
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
  copy('coverTotal', [
    'covers', 'cover', 'cover_total', 'coverTotal', 'pax', 'totalCover',
    'total_cover', 'coverCount', 'cover_count'
  ]);
  copy('apcTotal', [
    'apcTotal', 'apc_total', 'apc', 'averagePerCover', 'average_per_cover',
    'avgPerCover', 'avg_per_cover', 'averageCover', 'average_cover'
  ]);
  copy('orderTotal', [
    'orders', 'order_count', 'orderCount', 'order_total', 'orderTotal',
    'totalOrders', 'total_orders'
  ]);
  copy('avgRevenue', [
    'avgRevenue', 'avg_revenue', 'avgRevenuePerBill',
    'avg_revenue_per_bill', 'averageRevenuePerBill',
    'average_revenue_per_bill', 'avgRevPerBill', 'avg_rev_per_bill'
  ]);
  copy('voidBill', [
    'voidBill', 'void_bill', 'voidBills', 'void_bills', 'voidBillCount',
    'void_bill_count', 'voidCount', 'void_count'
  ]);
  copy('modifiedBill', [
    'modifiedBill', 'modified_bill', 'modifiedBills', 'modified_bills',
    'modifiedBillCount', 'modified_bill_count', 'modifyBill', 'modify_bill'
  ]);
  copy('complementary', [
    'complementary', 'complimentary', 'complementaryBill', 'complimentaryBill',
    'complementary_bill', 'complimentary_bill', 'complementaryBills',
    'complimentaryBills'
  ]);
  copy('netSaleDineIn', [
    'netSaleDineIn', 'net_sale_dine_in', 'dineInNetSale', 'dine_in_net_sale',
    'dineNetSale', 'dine_net_sale'
  ]);
  copy('apcDineIn', [
    'apcDineIn', 'apc_dine_in', 'dineInApc', 'dine_in_apc',
    'dineApc', 'dine_apc'
  ]);
  copy('coverDineIn', [
    'coverDineIn', 'cover_dine_in', 'dineInCover', 'dine_in_cover',
    'dineInCovers', 'dine_in_covers'
  ]);
  copy('customerServed', [
    'customers_served', 'customer_served', 'customerServed',
    'customersServed', 'customerCount', 'customer_count'
  ]);
  copy('unSatteledAmount', [
    'pending_amount', 'pendingAmount', 'pending_amt', 'unsettled_amount',
    'unsettledAmount', 'unSettledAmount', 'unSatteledAmount'
  ]);
  copy('unSatteledBill', [
    'pending_bill', 'pending_bills', 'pendingBill', 'pendingBills',
    'unsettled_bill', 'unsettled_bills', 'unsettledBill', 'unsettledBills',
    'unSatteledBill'
  ]);
  return r;
}

class _DashboardPageState extends State<DashboardPage> with WidgetsBindingObserver {
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
    WidgetsBinding.instance.addObserver(this);
    _restoreCachedSnapshot().then((_) => load());
    timer =
        Timer.periodic(const Duration(seconds: refreshSeconds), (_) => load());
  }

  String _cacheKey(String outletId) =>
      'dashboard_${apiDate(from)}_${apiDate(to)}_${outletId.isEmpty ? '0' : outletId}';

  Future<void> _restoreCachedSnapshot({String? outletId}) async {
    final id = outletId ?? widget.selectedOutlet;
    final cached = await OfflineStore.read(_cacheKey(id));
    if (!mounted || cached == null) {
      return;
    }
    final response = responseMap(cached);
    if (response.isEmpty) {
      return;
    }
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
      if (liveRows.isNotEmpty) {
        outletList = _mergeOutlets(outletList, liveRows);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !loading) {
      unawaited(load());
    }
  }

  Future<Map<String, dynamic>> _loadDashboardFor({
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    final requestFrom = fromDate ?? from;
    final requestTo = toDate ?? to;
    return responseMap(await widget.api
        .dashboard(
          apiDate(requestFrom),
          apiDate(requestTo),
        )
        .timeout(const Duration(seconds: 20)));
  }

  Future<void> load({
    String? outletId,
    bool forceAllOutlets = false,
    bool resetOutlet = false,
    bool force = false,
  }) async {
    // Periodic refreshes never overlap. Filter/date actions pass force=true so
    // the new request immediately supersedes any older in-flight request.
    if (loading && !force) {
      return;
    }
    final request = ++requestId;
    final requestFrom = DateTime(from.year, from.month, from.day);
    final requestTo = DateTime(to.year, to.month, to.day);
    final selectedId = resetOutlet
        ? '0'
        : (forceAllOutlets
            ? '0'
            : normalizedId(outletId ?? widget.selectedOutlet));
    if (resetOutlet) {
      widget.onOutletChanged('0', 'All Outlets');
    }
    if (mounted) {
      setState(() {
        loading = true;
      });
    }

    Future<Map<String, dynamic>> loadPrevious() async {
      try {
        final previousFrom = requestFrom.subtract(const Duration(days: 7));
        final previousTo = requestTo.subtract(const Duration(days: 7));
        return await _loadDashboardFor(
          fromDate: previousFrom,
          toDate: previousTo,
        );
      } catch (_) {
        return <String, dynamic>{};
      }
    }

    Future<Map<String, dynamic>> loadTopItems() async {
      try {
        return responseMap(await widget.api
            .topSellingItems()
            .timeout(const Duration(seconds: 15)));
      } catch (_) {
        // Internal marker only. It lets the UI retain the previous same-scope
        // top-items snapshot on a transient failure without confusing a valid
        // successful empty result with an error.
        return <String, dynamic>{'_requestFailed': true};
      }
    }

    // Start independent requests together. The previous-period comparison and
    // top-item list no longer wait for the current dashboard request to finish.
    final previousFuture = loadPrevious();
    final topItemsFuture = loadTopItems();

    try {
      // Dashboard/Sale is most complete and stable with ids=0. Keep one
      // authoritative aggregate response and select an outlet locally from its
      // original outlet rows. This avoids partial outlet-scoped responses that
      // may contain only Net Sale and blank the other dashboard cards.
      final aggregateResponse = await _loadDashboardFor(
        fromDate: requestFrom,
        toDate: requestTo,
      );

      if (!mounted || request != requestId) {
        return;
      }

      final allOutletRows = outletRowsFromApi(aggregateResponse)
          .map(normalizeApiMetricRow)
          .toList();
      final aggregateSummaryRows = summaryRowsFromApi(aggregateResponse)
          .map(normalizeApiMetricRow)
          .toList();
      final perOutletMetricRows = allOutletRows.isNotEmpty
          ? allOutletRows
          : aggregateSummaryRows
              .where((row) => outletIdOf(row).isNotEmpty)
              .toList();
      final rawSummary = field(aggregateResponse, [
        'summary',
        'saleSummary',
        'salesummary',
        'salesSummary',
        'sale',
      ]);
      // Only a real root summary Map is a combined All-Outlets total. If
      // the API returns a LIST of per-outlet summaries, keep that list intact
      // and let totals() add those original rows. Treating the first row as a
      // combined summary would silently show one outlet as All Outlets.
      final combinedSummaryMap = rawSummary is Map
          ? normalizeApiMetricRow(Map<String, dynamic>.from(rawSummary))
          : <String, dynamic>{};
      final aggregateLiveRows = rowsFromResponse(
        aggregateResponse,
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

      // A successful sync replaces the outlet directory instead of endlessly
      // merging stale names/removed outlets. If the endpoint does not expose an
      // outlet directory in this response, keep the last known list.
      final freshOutletList = _mergeOutlets(
        const <Map<String, dynamic>>[],
        [...allOutletRows, ...aggregateSummaryRows, ...aggregateLiveRows],
      );
      if (freshOutletList.isNotEmpty) {
        outletList = freshOutletList;
      }
      apiOutletRows = allOutletRows;
      apiCombinedSummary = combinedSummaryMap;
      widget.onOutletsChanged?.call(
        List<Map<String, dynamic>>.from(outletList),
      );

      String selectedName() {
        if (selectedId == '0') {
          return 'All Outlets';
        }
        for (final outlet in outletList) {
          if (outletIdOf(outlet) == selectedId) {
            return outletNameOf(outlet);
          }
        }
        return selectedOutletNameForDashboard;
      }

      final selectedOutletName = selectedName();
      final combinedSummary = <Map<String, dynamic>>[];
      final combinedLive = <Map<String, dynamic>>[];
      final combinedItems = <Map<String, dynamic>>[];
      final performanceRows = <Map<String, dynamic>>[];

      if (selectedId == '0') {
        if (combinedSummaryMap.isNotEmpty) {
          combinedSummary.add(combinedSummaryMap);
        } else {
          combinedSummary.addAll(aggregateSummaryRows);
        }

        for (final row in perOutletMetricRows) {
          final id = outletIdOf(row);
          if (id.isEmpty || id == '0') {
            continue;
          }
          performanceRows.add({
            'id': id,
            'name': outletNameOf(row),
            'gross': number(field(row, [
              'grossTotal',
              'grossSale',
              'gross_sale',
              'grossAmount',
              'totalGross',
              'gross',
              'gross_total',
              'total_gross',
            ])),
            'net': number(field(row, [
              'netTotal',
              'netSale',
              'net_sale',
              'netAmount',
              'totalNet',
              'net',
              'net_total',
              'total_net',
            ])),
          });
        }
        combinedLive.addAll(aggregateLiveRows);
      } else {
        final selectedSummaryRows = scopedDashboardSummaryRows(
          aggregateResponse,
          selectedId,
          outletName: selectedOutletName,
          responseAlreadyScoped: false,
        );
        combinedSummary.addAll(selectedSummaryRows);

        for (final row in selectedSummaryRows.take(1)) {
          performanceRows.add({
            'id': selectedId,
            'name': outletNameOf(row) == 'Outlet'
                ? selectedOutletName
                : outletNameOf(row),
            'gross': number(field(row, [
              'grossTotal',
              'grossSale',
              'gross_sale',
              'grossAmount',
              'gross_amount',
              'totalGross',
              'gross',
              'gross_total',
              'total_gross',
              'grossSales',
              'gross_sales',
            ])),
            'net': number(field(row, [
              'netTotal',
              'netSale',
              'net_sale',
              'netAmount',
              'net_amount',
              'totalNet',
              'net',
              'net_total',
              'total_net',
            ])),
          });
        }

        combinedLive.addAll(_scopeSelectedDashboardRows(
          aggregateLiveRows,
          selectedId,
          selectedOutletName,
        ));
      }

      final topResponse = await topItemsFuture;
      if (!mounted || request != requestId) {
        return;
      }
      final topRequestFailed = topResponse['_requestFailed'] == true;
      final topRows = _itemRowsFromResponse(topResponse);
      final dashboardItemRows = _itemRowsFromResponse(aggregateResponse);
      if (selectedId == '0') {
        combinedItems.addAll(
          topRows.isNotEmpty ? topRows : dashboardItemRows,
        );
      } else {
        final topScoped = _scopeSelectedDashboardRows(
          topRows,
          selectedId,
          selectedOutletName,
        );
        final dashboardScoped = _scopeSelectedDashboardRows(
          dashboardItemRows,
          selectedId,
          selectedOutletName,
        );
        combinedItems.addAll(
          topScoped.isNotEmpty ? topScoped : dashboardScoped,
        );
      }
      if (combinedItems.isEmpty &&
          topRequestFailed &&
          directItemRowsCache.isNotEmpty) {
        // Preserve only the already-selected/date-scoped cache. selectOutlet()
        // and pickDate() clear it, so data never leaks across filters.
        combinedItems.addAll(directItemRowsCache);
      }

      final responseForUi = Map<String, dynamic>.from(aggregateResponse);
      responseForUi['saleSummary'] = combinedSummary;
      responseForUi['liveSale'] = combinedLive;
      responseForUi['items'] = combinedItems;

      final rawPreviousResponse = await previousFuture;
      if (!mounted || request != requestId) {
        return;
      }
      final previousResponseForUi =
          Map<String, dynamic>.from(rawPreviousResponse);
      if (rawPreviousResponse.isNotEmpty) {
        if (selectedId == '0') {
          final previousSummary = summaryRowsFromApi(rawPreviousResponse)
              .map(normalizeApiMetricRow)
              .toList();
          final previousRawSummary = field(rawPreviousResponse, [
            'summary',
            'saleSummary',
            'salesummary',
            'salesSummary',
            'sale',
          ]);
          previousResponseForUi['saleSummary'] = previousRawSummary is Map
              ? [
                  normalizeApiMetricRow(
                    Map<String, dynamic>.from(previousRawSummary),
                  )
                ]
              : previousSummary;
        } else {
          previousResponseForUi['saleSummary'] = scopedDashboardSummaryRows(
            rawPreviousResponse,
            selectedId,
            outletName: selectedOutletName,
            responseAlreadyScoped: false,
          );
        }
      }

      loadedOutletId = selectedId;
      previousLoadedOutletId = selectedId;
      setState(() {
        data = responseForUi;
        previousWeekData = previousResponseForUi;
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
        setState(() {
          loading = false;
        });
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
      if (id.isEmpty) {
        continue;
      }
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

  List<Map<String, dynamic>> _scopeSelectedDashboardRows(
    Iterable<Map<String, dynamic>> rows,
    String outletId,
    String outletName,
  ) {
    final source = rows.toList();
    if (source.isEmpty) {
      return const <Map<String, dynamic>>[];
    }
    // Dashboard is intentionally loaded with ids=0. Only rows that positively
    // identify the requested outlet may be shown for a single-outlet filter.
    // Never relabel an unscoped aggregate row as the selected outlet.
    return source
        .where((row) => rowMatchesOutlet(
              row,
              outletId,
              outletName: outletName,
            ))
        .where((row) =>
            outletIdOf(row).isNotEmpty || outletNameOf(row) != 'Outlet')
        .toList();
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
      force: true,
    );
  }

  Future<void> pickDate(bool isFrom) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isFrom ? from : to,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null) {
      return;
    }
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
    await load(force: true);
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
    if (id != '0' && loadedOutletId == id) {
      return summaries;
    }
    return summaryForOutlet(
      summaries,
      widget.selectedOutlet,
      outletName: selectedOutletNameForDashboard,
    );
  }

  String get selectedOutletNameForDashboard {
    if (normalizedId(widget.selectedOutlet) == '0') {
      return 'All Outlets';
    }
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
          if (seen.add(signature)) {
            found.add(row);
          }
        }
        for (final value in row.values) {
          if (value is Map || value is List) {
            walk(value);
          }
        }
      } else if (value is List) {
        for (final item in value) {
          if (item is Map || item is List) {
            walk(item);
          }
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
      if (value != null) {
        walk(value);
      }
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
      if (itemKey.isEmpty) {
        continue;
      }
      final old = map[key] ?? {
        'outletId': itemOutletId,
        'outletName': itemOutletName,
        'name': name,
        'qty': 0,
        'amount': 0,
      };
      old['qty'] = number(old['qty']) + itemQtyOf(item);
      old['amount'] = number(old['amount']) + itemAmountOf(item);
      if (old['name'] == 'Item' && name.isNotEmpty) {
        old['name'] = name;
      }
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
    // Dashboard itself is loaded as ids=0 and selection is local. Top-item
    // rows are therefore accepted for a selected outlet only when they carry
    // matching outlet metadata; this prevents cross-outlet leakage.
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
    // `outletPerformanceRows` and `apiOutletRows` both come from the same
    // authoritative ids=0 Dashboard response. The selected bar is built from
    // the exact same normalized outlet summary row used by its cards.
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
      if (current == 0) {
        return 0;
      }
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
                      await load();
                      await widget.onLiveSync();
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
              onPressed: loading ? null : () => load(force: true),
              icon: const Icon(Icons.refresh)),
          IconButton(
              onPressed: widget.onLogout, icon: const Icon(Icons.logout)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => load(force: true),
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
                style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
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

class _LiveTablesPageState extends State<LiveTablesPage> with WidgetsBindingObserver {
  List<Map<String, dynamic>> live = [];
  List<Map<String, dynamic>> summaryRows = [];
  bool loading = false;
  Timer? timer;
  String selectedOutletId = '0';
  int requestId = 0;
  late final VoidCallback _syncListener;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    selectedOutletId = widget.outletId.trim().isEmpty ? '0' : widget.outletId.trim();
    _syncListener = () {
      if (mounted) {
        // A user-requested LIVE sync must not be dropped merely because a
        // periodic request is in flight; force=true supersedes the old request.
        unawaited(load(force: true));
      }
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
    WidgetsBinding.instance.removeObserver(this);
    widget.syncSignal.removeListener(_syncListener);
    timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !loading) {
      unawaited(load(force: true));
    }
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
    final oldOutletSignature = oldWidget.availableOutlets
        .map((row) => '${outletIdOf(row)}|${outletNameOf(row)}')
        .join('||');
    final newOutletSignature = widget.availableOutlets
        .map((row) => '${outletIdOf(row)}|${outletNameOf(row)}')
        .join('||');
    if (oldId != newId ||
        oldWidget.outletName != widget.outletName ||
        oldOutletSignature != newOutletSignature) {
      selectedOutletId = newId;
      unawaited(load(resetOutlet: false, force: true));
    }
  }

  Future<void> _restoreCachedLive() async {
    final cacheId = normalizedId(widget.outletId).isEmpty ? '0' : normalizedId(widget.outletId);
    final cacheKey = 'live_$cacheId';
    final cached = await OfflineStore.read(cacheKey);
    if (!mounted || cached == null) {
      return;
    }
    final response = responseMap(cached);
    if (response.isEmpty) {
      return;
    }
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
    if (rows.isEmpty && summaries.isEmpty) {
      return;
    }
    // A cache read may finish after the user changes outlet/date. Never let an
    // old snapshot overwrite the newly selected filter.
    final currentCacheId = normalizedId(widget.outletId).isEmpty ? '0' : normalizedId(widget.outletId);
    final currentCacheKey = 'live_$currentCacheId';
    if (cacheKey != currentCacheKey) {
      return;
    }
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

  List<Map<String, dynamic>> _extractLiveItems(Map<String, dynamic> response) {
    final found = <Map<String, dynamic>>[];
    final seen = <String>{};
    final itemKeys = const [
      'itms', 'items', 'itemList', 'item_list', 'itemDetails', 'item_details',
      'saleItems', 'sale_items', 'billItems', 'bill_items', 'details',
    ];

    bool looksLikeItem(Map<String, dynamic> row) {
      final keys = row.keys.map((e) => e.toString().toLowerCase()).toSet();
      final hasName = keys.any((key) =>
          key == 'i_name' || key == 'item_name' || key == 'itemname' ||
          key == 'itemdesc' || key == 'item_desc' || key == 'productname' ||
          key == 'product_name' || key == 'name' || key == 'description');
      final hasQty = keys.any((key) =>
          key == 'qty' || key == 'quantity' || key == 'qtyvalue' ||
          key == 'qty_value' || key == 'item_qty' || key == 'itemqty');
      return hasName && hasQty;
    }

    void walk(dynamic value) {
      if (value is Map) {
        final row = Map<String, dynamic>.from(value);
        if (looksLikeItem(row)) {
          final name = stringValue(
            field(row, ['i_Name', 'i_name', 'item_name', 'itemName', 'name']),
            'Item',
          );
          final qty = number(field(row, ['qty', 'quantity', 'qtyValue', 'qty_value']));
          final amount = number(field(row, ['amount', 'item_amount', 'itemAmount', 'total']));
          final code = stringValue(field(row, ['i_Code', 'item_code', 'itemCode', 'code']));
          final signature = '$code|$name|$qty|$amount';
          if (seen.add(signature)) {
            found.add(row);
          }
        }
        for (final entry in row.entries) {
          if (itemKeys.any((key) => key.toLowerCase() == entry.key.toString().toLowerCase()) ||
              entry.value is Map || entry.value is List) {
            walk(entry.value);
          }
        }
      } else if (value is List) {
        for (final entry in value) {
          if (entry is Map || entry is List) {
            walk(entry);
          }
        }
      }
    }

    walk(response);
    return found;
  }

  Future<Map<String, dynamic>> _loadLiveFor(String outletId) async {
    final id = normalizedId(outletId).isEmpty ? '0' : normalizedId(outletId);

    // The POS LiveTableItem/Sale contract exposes the complete live-table
    // dataset with bill_no=0. Loading that dataset directly removes the old
    // Dashboard -> bill discovery -> N bill-detail waterfall and makes sync
    // much faster and less failure-prone.
    final response = responseMap(await widget.api
        .liveTable(id, '0')
        .timeout(const Duration(seconds: 20)));

    final rawLiveRows = _extractLive(response);
    final normalizedLiveRows = <Map<String, dynamic>>[];
    for (final original in rawLiveRows) {
      final row = Map<String, dynamic>.from(original);
      final explicitId = explicitOutletIdOf(row);
      if (id != '0' && explicitId.isNotEmpty && explicitId != id) {
        // If a legacy server ignores outlet_id and sends aggregate data, do not
        // leak another outlet into the selected outlet's screen.
        continue;
      }
      if (id != '0' && explicitId.isEmpty) {
        row['outlet_id'] = id;
        row['outletId'] = id;
      }
      if (id != '0' && explicitOutletNameOf(row).isEmpty) {
        final name = selectedOutletNameForLive(id);
        if (name.isNotEmpty) {
          row['outlet_name'] = name;
          row['outletName'] = name;
        }
      }

      // Table master/name fields differ across POS versions. Search the entire
      // response for the same bill before giving up, then preserve the original
      // POS value under t_Name so the UI renders it consistently.
      if (tableDisplayNameOf(row) == '—') {
        final discoveredName = _findTableNameInResponse(
          response,
          billNo: billNoOf(row),
          tableNo: tableNoOf(row),
        );
        if (discoveredName.isNotEmpty) {
          row['t_Name'] = discoveredName;
        }
      }
      normalizedLiveRows.add(row);
    }

    final explicitSummaryRows = _extractSummary(response);
    final normalizedSummaryRows = <Map<String, dynamic>>[];
    for (final original in explicitSummaryRows) {
      final row = Map<String, dynamic>.from(original);
      final explicitId = explicitOutletIdOf(row);
      if (id != '0' && explicitId.isNotEmpty && explicitId != id) {
        continue;
      }
      if (id != '0' && explicitId.isEmpty) {
        row['outlet_id'] = id;
        row['outletId'] = id;
      }
      if (id != '0' && explicitOutletNameOf(row).isEmpty) {
        final name = selectedOutletNameForLive(id);
        if (name.isNotEmpty) {
          row['outlet_name'] = name;
          row['outletName'] = name;
        }
      }
      normalizedSummaryRows.add(row);
    }

    // Prefer a real summary block returned by LiveTableItem/Sale. When that
    // deployment exposes financial totals only at the root, capture the root
    // fields once instead of summing per-table rows and double counting.
    if (normalizedSummaryRows.isEmpty) {
      final rootSummary = <String, dynamic>{};
      for (final key in const [
        'grossTotal',
        'grossSale',
        'gross_sale',
        'gross_total',
        'grossAmount',
        'gross_amount',
        'totalGross',
        'total_gross',
        'netTotal',
        'netSale',
        'net_sale',
        'net_total',
        'netAmount',
        'net_amount',
        'totalNet',
        'total_net',
        'unSatteledAmount',
        'unSettledAmount',
        'unsettledAmount',
        'pendingAmount',
        'pendingAmt',
        'pending_amt',
        'settlementPending',
        'pendingSettlement',
      ]) {
        final value = field(response, [key]);
        if (value != null) {
          rootSummary[key] = value;
        }
      }
      if (rootSummary.isNotEmpty) {
        if (id != '0') {
          rootSummary['outlet_id'] = id;
          rootSummary['outletId'] = id;
          final name = selectedOutletNameForLive(id);
          if (name.isNotEmpty) {
            rootSummary['outlet_name'] = name;
            rootSummary['outletName'] = name;
          }
        }
        normalizedSummaryRows.add(rootSummary);
      }
    }

    return {
      'liveSale': normalizedLiveRows,
      'saleSummary': normalizedSummaryRows,
    };
  }

  String _findTableNameInResponse(
    Map<String, dynamic> response, {
    String billNo = '',
    String tableNo = '',
  }) =>
      resolveTableNameFromResponse(
        response,
        billNo: billNo,
        tableNo: tableNo,
      );

  List<Map<String, dynamic>> _scopeLiveRows(
      Iterable<Map<String, dynamic>> rows, String outletId) {
    final id = normalizedId(outletId);
    if (id.isEmpty || id == '0') {
      return rows.where((row) => outletIdOf(row).isNotEmpty).toList();
    }
    final name = selectedOutletNameForLive(id);
    final scoped = <Map<String, dynamic>>[];
    for (final original in rows) {
      final row = Map<String, dynamic>.from(original);
      final rowId = explicitOutletIdOf(row).isNotEmpty
          ? explicitOutletIdOf(row)
          : outletIdOf(row);
      final explicitName = explicitOutletNameOf(row);
      final rowName = explicitName.isNotEmpty ? explicitName : outletNameOf(row);
      if (rowId.isNotEmpty && rowId != id) {
        continue;
      }
      if (rowId.isEmpty &&
          rowName != 'Outlet' &&
          name.isNotEmpty &&
          rowName.toLowerCase() != name.toLowerCase()) {
        continue;
      }
      if (rowId.isEmpty) {
        row['outlet_id'] = id;
        row['outletId'] = id;
      }
      if (rowName == 'Outlet' && name.isNotEmpty) {
        row['outlet_name'] = name;
        row['outletName'] = name;
      }
      scoped.add(row);
    }
    return scoped;
  }

  String selectedOutletNameForLive(String id) {
    for (final outlet in widget.availableOutlets) {
      if (outletIdOf(outlet) == id) {
        return outletNameOf(outlet);
      }
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

  List<Map<String, dynamic>> _extractSummary(
      Map<String, dynamic> response) {
    for (final key in const [
      'saleSummary',
      'salesummary',
      'salesSummary',
      'summary',
    ]) {
      final rows = asRows(field(response, [key]));
      if (rows.isNotEmpty) {
        return rows;
      }
    }

    // A legacy LiveTableItem deployment uses `sale` for a true summary block.
    // Accept only rows that contain financial fields and are not bill/table
    // rows, so a list of live bills can never be double-counted as a summary.
    final legacySaleRows = asRows(field(response, const ['sale']));
    final safeLegacySummary = legacySaleRows.where((row) {
      final hasFinancial = field(row, const [
            'grossTotal', 'grossSale', 'gross_sale', 'gross_total',
            'netTotal', 'netSale', 'net_sale', 'net_total',
            'pendingAmount', 'pending_amount', 'unsettledAmount',
            'unSatteledAmount',
          ]) !=
          null;
      final hasBill = billNoOf(row).trim().isNotEmpty;
      final tableNo = tableNoOf(row).trim();
      final hasTable = (tableNo.isNotEmpty && tableNo != '—' && tableNo != '-') ||
          tableDisplayNameOf(row) != '—';
      return hasFinancial && !hasBill && !hasTable;
    }).toList();
    if (safeLegacySummary.isNotEmpty) {
      return safeLegacySummary;
    }

    // Do not recursively treat every table/bill row as an outlet summary.
    // Root financial fields are handled once by _loadLiveFor.
    return const <Map<String, dynamic>>[];
  }

  Future<void> load({bool resetOutlet = false, bool force = false}) async {
    if (loading && !force) {
      return;
    }
    final request = ++requestId;
    final selected = resetOutlet
        ? '0'
        : (normalizedId(selectedOutletId).isEmpty
            ? '0'
            : normalizedId(selectedOutletId));
    if (resetOutlet) {
      setState(() {
        selectedOutletId = '0';
      });
    }
    if (mounted) {
      setState(() {
        loading = true;
      });
    }

    try {
      final freshLive = <Map<String, dynamic>>[];
      final freshSummary = <Map<String, dynamic>>[];
      final failedOutlets = <String>{};
      var globalFailure = false;

      if (selected == '0') {
        final ids = widget.availableOutlets
            .map(outletIdOf)
            .where((id) => id.isNotEmpty && id != '0')
            .toSet()
            .toList();
        if (ids.isEmpty) {
          try {
            final response = await _loadLiveFor('0');
            freshLive.addAll(_extractLive(response));
            freshSummary.addAll(_extractSummary(response));
          } catch (_) {
            globalFailure = true;
          }
        } else {
          // Keep the sync fast without creating an unbounded request burst on
          // installations with many outlets. Four outlet calls run in parallel
          // per batch; failed outlets keep their previous snapshot below.
          const batchSize = 4;
          for (var start = 0; start < ids.length; start += batchSize) {
            final end = start + batchSize < ids.length
                ? start + batchSize
                : ids.length;
            final batch = ids.sublist(start, end);
            final results = await Future.wait(batch.map((id) async {
              try {
                final response = await _loadLiveFor(id);
                return (
                  outletId: id,
                  success: true,
                  live: _scopeLiveRows(_extractLive(response), id),
                  summary: _scopeLiveRows(_extractSummary(response), id),
                );
              } catch (_) {
                return (
                  outletId: id,
                  success: false,
                  live: <Map<String, dynamic>>[],
                  summary: <Map<String, dynamic>>[],
                );
              }
            }));
            for (final result in results) {
              if (!result.success) {
                failedOutlets.add(result.outletId);
                continue;
              }
              freshLive.addAll(result.live);
              freshSummary.addAll(result.summary);
            }
          }
        }
      } else {
        try {
          final response = await _loadLiveFor(selected);
          freshLive.addAll(_scopeLiveRows(_extractLive(response), selected));
          freshSummary.addAll(_scopeLiveRows(_extractSummary(response), selected));
        } catch (_) {
          failedOutlets.add(selected);
        }
      }

      if (!mounted || request != requestId) {
        return;
      }

      // Same-date refresh is stale-while-revalidate: a temporary network/API
      // failure must never blank the screen. A successful outlet response can
      // replace that outlet's previous snapshot, while failed outlets retain
      // their last known-good data until the next sync succeeds.
      List<Map<String, dynamic>> nextLive;
      List<Map<String, dynamic>> nextSummary;
      if (selected == '0') {
        if (globalFailure) {
          nextLive = List<Map<String, dynamic>>.from(live);
          nextSummary = List<Map<String, dynamic>>.from(summaryRows);
        } else {
          final keptLive = live.where((row) {
            final id = outletIdOf(row);
            return id.isNotEmpty && failedOutlets.contains(id);
          }).toList();
          final keptSummary = summaryRows.where((row) {
            final id = outletIdOf(row);
            return id.isNotEmpty && failedOutlets.contains(id);
          }).toList();
          nextLive = [...freshLive, ...keptLive];
          nextSummary = [...freshSummary, ...keptSummary];
        }
      } else if (failedOutlets.contains(selected)) {
        nextLive = List<Map<String, dynamic>>.from(live);
        nextSummary = List<Map<String, dynamic>>.from(summaryRows);
      } else {
        nextLive = freshLive;
        nextSummary = freshSummary;
      }

      // A successful empty response is meaningful: a table may have been
      // settled/closed/removed. Only failed requests preserve stale data.
      setState(() {
        live = nextLive;
        summaryRows = nextSummary;
        selectedOutletId = selected;
      });
      final cacheKey = 'live_$selected';
      await OfflineStore.save(cacheKey, {
        'liveSale': nextLive,
        'saleSummary': nextSummary,
      });
    } catch (_) {
      // Preserve the last successful snapshot. The next scheduled sync retries.
    } finally {
      if (mounted && request == requestId) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  List<Map<String, dynamic>> get outlets {
    final map = <String, Map<String, dynamic>>{};
    for (final row in [...live, ...summaryRows]) {
      final id = outletIdOf(row);
      if (id.isEmpty) {
        continue;
      }
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
      if (id.isEmpty || id == '0') {
        continue;
      }
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
    final tableName = tableDisplayNameOf(row).trim();
    final bill = billNoOf(row).trim();
    final hasTableNo =
        table.isNotEmpty && table != '—' && table != '-' && table != '0';
    final hasTableName = tableName.isNotEmpty &&
        tableName != '—' &&
        tableName != '-' &&
        tableName != '0';
    if (!hasTableNo && !hasTableName) {
      return false;
    }
    if (bill.isEmpty) {
      return false;
    }
    final rawStatus = field(row, ['bill_status', 'billStatus', 'status']);
    if (rawStatus == null) {
      return true;
    }
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
        final tableName = tableDisplayNameOf(r).trim();
        final bill = billNoOf(r).trim();
        final hasTableNo =
            table.isNotEmpty && table != '—' && table != '-' && table != '0';
        final hasTableName = tableName.isNotEmpty &&
            tableName != '—' &&
            tableName != '-' &&
            tableName != '0';
        return (hasTableNo || hasTableName) && bill.isNotEmpty;
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

  num _metric(List<String> summaryNames) {
    // Live Tables financial cards have exactly one source of truth:
    // LiveTableItem/Sale response rows. Never fall back to table-card values,
    // Dashboard/Sale, Net Sale, Avg Revenue, Order Count, or any derived value.
    // All Outlets aggregates the original API field across outlet-scoped rows;
    // a single outlet uses only that outlet's original API rows.
    if (selectedSummaries.isEmpty) {
      return 0;
    }
    return _sumRows(selectedSummaries, summaryNames);
  }

  String get selectedOutletName {
    if (selectedOutletId == '0') {
      return 'All Outlets';
    }
    for (final outlet in outlets) {
      if (outletIdOf(outlet) == selectedOutletId) {
        return outletNameOf(outlet);
      }
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
    if (bill.isEmpty || outlet.isEmpty || outlet == '0') {
      return;
    }

    final cachedItems = asRows(field(table, ['_items', 'items', 'itms']));
    final future = cachedItems.isNotEmpty
        ? Future<Map<String, dynamic>>.value({'itms': cachedItems})
        : widget.api.liveTable(outlet, bill).then(responseMap);
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
              final items = _extractLiveItems(detail ?? {});
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
    final rows = liveTableCandidates;
    // All financial cards in this page are calculated only from successful
    // LiveTableItem/Sale responses. Dashboard/Sale is never a financial
    // fallback for Live Tables.
    final gross = _metric(['grossTotal', 'grossSale', 'gross_sale', 'grossAmount', 'gross_amount', 'totalGross', 'total_gross'],
    );
    final net = _metric(['netTotal', 'netSale', 'net_sale', 'netAmount', 'net_amount', 'totalNet', 'total_net'],
    );
    final pending = _metric([
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
              onPressed: loading ? null : () => load(force: true),
              icon: const Icon(Icons.refresh)),
          IconButton(
              onPressed: widget.onLogout, icon: const Icon(Icons.logout)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => load(force: true),
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
            const Text('Auto refresh every 30 seconds',
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
                    if (value == null || value == selectedOutletId) {
                      return;
                    }
                    setState(() => selectedOutletId = value);
                    await load(force: true);
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
                  final running = _isActualLiveTable(row);
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
    if (loading) {
      return;
    }
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
        if (!mounted || request != requestId) {
          return;
        }
        setState(() => processingText =
            'Syncing ${_periodName()} · ${offset + 1}-${offset + batch.length}/${ranges.length}');
        final batchResults = await Future.wait(batch.map(_fetchRange));
        if (!mounted || request != requestId) {
          return;
        }
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
        );
        final response = responseMap(json);
        Map<String, dynamic> previousResponse = {};
        try {
          final previousFrom = full.$1.subtract(const Duration(days: 7));
          final previousTo = full.$2.subtract(const Duration(days: 7));
          final previousJson = await widget.api.dashboard(
            apiDate(previousFrom),
            apiDate(previousTo),
          );
          previousResponse = responseMap(previousJson);
        } catch (_) {}
        final selected = scopedDashboardSummaryRows(
          response,
          reportOutletId,
          outletName: widget.outletName,
          responseAlreadyScoped: false,
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
      if (mounted && request == requestId) setState(() {
      loading = false;
    });
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
      );
      final response = responseMap(json);
      final selected = scopedDashboardSummaryRows(
        response,
        reportOutletId,
        outletName: widget.outletName,
        responseAlreadyScoped: false,
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
                            if (period == i || loading) {
                              return;
                            }
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
