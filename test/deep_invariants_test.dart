import 'package:flutter_test/flutter_test.dart';
import 'package:suvidhalivesale/main.dart';

void main() {
  test('50x dashboard outlet matrix never substitutes Net for Gross', () {
    for (var run = 1; run <= 50; run++) {
      final rows = <Map<String, dynamic>>[
        {
          'outletId': '1',
          'outletName': 'Wild Sage',
          'grossTotal': 311825 + run,
          'netTotal': 292013.01 + run,
          'taxTotal': 24002.61,
          'discountTotal': 138922.48,
        },
        {
          'outletId': '2',
          'outletName': 'MOBE Panchkula',
          'grossTotal': 190426 + run,
          'netTotal': 169677.84 + run,
          'taxTotal': 20749.67,
          'discountTotal': 11583.18,
        },
        {
          'outletId': '3',
          'outletName': 'TRIPT',
          'grossTotal': 57429 + run,
          'netTotal': 54236.78 + run,
          'taxTotal': 3193.06,
          'discountTotal': 5820.90,
        },
      ];

      for (final id in ['1', '2', '3']) {
        final selected = summaryForOutlet(rows, id);
        expect(selected, hasLength(1));
        final row = selected.single;
        final gross = dashboardGrossValue(row);
        final net = number(row['netTotal']);
        expect(gross, greaterThan(0));
        expect(gross, equals(number(row['grossTotal'])));
        expect(gross, isNot(equals(net)));
      }

      final all = summaryForOutlet(rows, '0');
      expect(all, hasLength(3));
      expect(
        all.fold<num>(0, (sum, row) => sum + dashboardGrossValue(row)),
        equals(rows.fold<num>(0, (sum, row) => sum + number(row['grossTotal']))),
      );
    }
  });

  test('50x missing Gross cases stay zero instead of becoming Net', () {
    for (var run = 0; run < 50; run++) {
      final row = <String, dynamic>{
        'outletId': '1',
        'outletName': 'Wild Sage',
        'netTotal': 1000 + run,
        'avgRevenue': 100 + run,
        'orderTotal': 10,
      };
      expect(dashboardGrossValue(row), 0);
      expect(dashboardGrossValue(row), isNot(equals(number(row['netTotal']))));
    }
  });

  test('50x table-name display keeps Table No label and POS name', () {
    for (var run = 0; run < 50; run++) {
      final name = 'WS${run + 1}';
      expect(
        tableDisplayNameOf({
          'tableNo': run + 1,
          'tableName': name,
        }),
        name,
      );
    }
  });
}
