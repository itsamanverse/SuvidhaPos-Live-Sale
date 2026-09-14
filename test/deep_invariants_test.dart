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

  test('aggregate response never relabels combined summary as selected outlet', () {
    final rows = scopedDashboardSummaryRows(
      {
        'summary': {
          'gross_sale': 9999,
          'net_sale': 8888,
        },
        'outlets': [
          {
            'outlet_id': '1',
            'outlet_name': 'Outlet 1',
            'gross_sale': 1200,
            'net_sale': 1100,
          },
          {
            'outlet_id': '2',
            'outlet_name': 'Outlet 2',
            'gross_sale': 2200,
            'net_sale': 2000,
          },
        ],
      },
      '2',
      outletName: 'Outlet 2',
      responseAlreadyScoped: false,
    );
    expect(rows, hasLength(1));
    expect(outletIdOf(rows.first), '2');
    expect(number(field(rows.first, ['grossTotal'])), 2200);
    expect(number(field(rows.first, ['netTotal'])), 2000);
  });

  test('same-outlet partial rows merge aliases without adding totals', () {
    final rows = scopedDashboardSummaryRows(
      {
        'outlets': [
          {
            'outlet_id': '7',
            'outlet_name': 'Wild Sage',
            'net_sale': 292013.01,
          },
        ],
        'saleSummary': [
          {
            'outlet_id': '7',
            'outlet_name': 'Wild Sage',
            'gross_sale': 311825,
            'tax': 19811.99,
            'void_bill_count': 3,
            'unsettled_bills': 4,
          },
        ],
      },
      '7',
      outletName: 'Wild Sage',
      responseAlreadyScoped: false,
    );
    expect(rows, hasLength(1));
    expect(number(field(rows.first, ['grossTotal'])), 311825);
    expect(number(field(rows.first, ['netTotal'])), 292013.01);
    expect(number(field(rows.first, ['taxTotal'])), 19811.99);
    expect(number(field(rows.first, ['voidBill'])), 3);
    expect(number(field(rows.first, ['unSatteledBill'])), 4);
  });

  test('dashboard metric aliases normalize all secondary cards', () {
    final row = normalizeApiMetricRow({
      'average_per_cover': 525,
      'void_bill_count': 2,
      'modified_bills': 3,
      'complimentary_bill': 4,
      'dine_in_net_sale': 1500,
      'dine_in_apc': 375,
      'dine_in_covers': 4,
      'customer_count': 12,
      'unsettled_amount': 700,
      'unsettled_bills': 2,
    });
    expect(number(row['apcTotal']), 525);
    expect(number(row['voidBill']), 2);
    expect(number(row['modifiedBill']), 3);
    expect(number(row['complementary']), 4);
    expect(number(row['netSaleDineIn']), 1500);
    expect(number(row['apcDineIn']), 375);
    expect(number(row['coverDineIn']), 4);
    expect(number(row['customerServed']), 12);
    expect(number(row['unSatteledAmount']), 700);
    expect(number(row['unSatteledBill']), 2);
  });

  test('table label understands live POS FK/name variants', () {
    expect(tableDisplayNameOf({'t_name_fk': 'TB8', 'tableNo': 8}), 'TB8');
    expect(tableDisplayNameOf({'TableNameFK': 'WS4', 'tableNo': 4}), 'WS4');
    expect(tableDisplayNameOf({'tblNameFk': 'Garden', 'tableNo': 9}), 'Garden');
    expect(tableDisplayNameOf({'tableTitle': 'Roof 2', 'tableNo': 10}), 'Roof 2');
    expect(tableDisplayNameOf({'t_NameFK': 12, 'tableNo': 12}), '—');
  });

  test('table name resolves from separate table-master row by table id', () {
    final response = {
      'liveSale': [
        {'bill_no': 'B-44', 'tableNo': 4},
      ],
      'tableMaster': [
        {'id': '3', 't_Name': 'TB3'},
        {'id': '4', 't_Name': 'WS4'},
      ],
    };
    expect(
      resolveTableNameFromResponse(
        Map<String, dynamic>.from(response),
        billNo: 'B-44',
        tableNo: '4',
      ),
      'WS4',
    );
  });

  test('live scoping never treats generic row id/name as outlet identity', () {
    final liveRow = {
      'id': '999',
      'name': 'Table Internal Row',
      'bill_no': 'B-12',
      't_Name': 'TB12',
    };
    expect(explicitOutletIdOf(liveRow), '');
    expect(explicitOutletNameOf(liveRow), '');
    expect(
      explicitOutletIdOf({'outlet_id': '7', 'id': '999'}),
      '7',
    );
    expect(
      explicitOutletNameOf({'outlet_name': 'Wild Sage', 'name': 'Other'}),
      'Wild Sage',
    );
  });

}
