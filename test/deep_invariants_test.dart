import 'package:flutter_test/flutter_test.dart';
import 'package:suvidhalivesale/main.dart';

void main() {
  test('explicit gross comes only from the Dashboard/Sale gross field', () {
    expect(
      dashboardGrossValue({'grossTotal': 311825, 'netTotal': 292013.01}),
      311825,
    );
  });

  test('missing gross is never derived from Avg Revenue and Order Count', () {
    expect(
      dashboardGrossValue({
        'netTotal': 24204,
        'avgRevenue': 1494.823529,
        'orderTotal': 17,
      }),
      0,
    );
  });

  test('zero gross never falls back to net', () {
    expect(dashboardGrossValue({'grossTotal': 0, 'netTotal': 54236.78}), 0);
  });

  test('multiple API rows are aggregated by their explicit gross fields', () {
    final rows = [
      {'grossTotal': 1000, 'netTotal': 900},
      {'grossTotal': 2000, 'netTotal': 1800},
    ];
    expect(dashboardGrossValue(rows), 3000);
  });
  test('table label uses original POS table name, never numeric tableNo', () {
    expect(tableDisplayNameOf({'tableNo': 1, 't_Name': 'TB1'}), 'TB1');
    expect(tableDisplayNameOf({'tableNo': 1, 'tableName': 'WS1'}), 'WS1');
    expect(
      tableDisplayNameOf({'tableNo': 1, 'table': {'t_Name': 'TB1'}}),
      'TB1',
    );
    expect(tableDisplayNameOf({'tableNo': 1}), '—');
  });

}
