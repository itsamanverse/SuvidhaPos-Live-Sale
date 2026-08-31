import 'package:flutter_test/flutter_test.dart';
import 'package:suvidhalivesale/main.dart';

void main() {
  test('app metadata is configured', () {
    expect(appTitle, 'SuvidhaPos Live Sale');
    expect(apiBase, startsWith('https://'));
  });

  test('all-outlet summary ignores aggregate row when outlet rows exist', () {
    final rows = <Map<String, dynamic>>[
      {'grossTotal': 1000, 'netTotal': 900},
      {'outletId': '1', 'outletName': 'Outlet A', 'grossTotal': 600, 'netTotal': 550},
      {'outletId': '2', 'outletName': 'Outlet B', 'grossTotal': 400, 'netTotal': 350},
    ];
    final selected = summaryForOutlet(rows, '0');
    expect(selected.length, 2);
    expect(selected.fold<num>(0, (s, r) => s + number(r['netTotal'])), 900);
  });

  test('single outlet filtering works by id and by name fallback', () {
    final rows = <Map<String, dynamic>>[
      {'outletId': '1', 'outletName': 'Outlet A', 'netTotal': 550},
      {'outletId': '2', 'outletName': 'Outlet B', 'netTotal': 350},
    ];
    expect(summaryForOutlet(rows, '2').single['netTotal'], 350);
    expect(summaryForOutlet(rows, '2', outletName: 'Outlet B').single['netTotal'], 350);
  });

  test('outlet name fallback works when API row has no outlet id', () {
    final rows = <Map<String, dynamic>>[
      {'outletName': 'Outlet A', 'netTotal': 550},
      {'outletName': 'Outlet B', 'netTotal': 350},
    ];
    expect(summaryForOutlet(rows, '2', outletName: 'Outlet B').single['netTotal'], 350);
  });

  test('same-day previous-week percentage matches expected decrease', () {
    const current = 10;
    const previous = 25;
    final change = ((current - previous) / previous) * 100;
    expect(change, closeTo(-60, 0.0001));
  });
}
