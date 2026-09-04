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
    expect(tableDisplayNameOf({'table_no': 'B1', 'tableNo': 1}), 'B1');
    expect(tableDisplayNameOf({'tableno': 'WS1'}), 'WS1');
    expect(tableDisplayNameOf({'tableNo': 1}), '—');
    expect(tableDisplayNameOf({'tableNo': 1}), '—');
  });

  test('selected dashboard prefers complete outlet row over net-only summary', () {
    final response = {
      'summary': {'net_sale': 292013.01},
      'outlets': [
        {
          'outlet_id': '7',
          'outlet_name': 'Wild Sage',
          'gross_sale': 311825,
          'net_sale': 292013.01,
          'tax': 19811.99,
          'discount': 5000,
          'order_count': 196,
        },
      ],
    };
    final rows = scopedDashboardSummaryRows(
      Map<String, dynamic>.from(response),
      '7',
      outletName: 'Wild Sage',
    );
    expect(rows, hasLength(1));
    expect(number(field(rows.first, ['gross_sale', 'grossTotal'])), 311825);
    expect(number(field(rows.first, ['tax', 'taxTotal'])), 19811.99);
  });

  test('selected scoped unlabelled summary gets outlet context', () {
    final rows = scopedDashboardSummaryRows(
      {
        'summary': {
          'gross_sale': 1000,
          'net_sale': 900,
          'tax': 100,
        },
      },
      '2',
      outletName: 'Outlet 2',
    );
    expect(rows, hasLength(1));
    expect(outletIdOf(rows.first), '2');
    expect(outletNameOf(rows.first), 'Outlet 2');
    expect(number(field(rows.first, ['gross_sale', 'grossTotal'])), 1000);
  });

}
