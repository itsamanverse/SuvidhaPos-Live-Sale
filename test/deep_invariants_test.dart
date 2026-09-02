import 'package:flutter_test/flutter_test.dart';
import 'package:suvidhalivesale/main.dart';

void main() {
  test('explicit gross is never replaced by net', () {
    expect(dashboardGrossValue({'grossTotal': 311825, 'netTotal': 292013.01}), 311825);
  });

  test('gross can be derived from average revenue and order count', () {
    expect(dashboardGrossValue({'netTotal': 24204, 'avgRevenue': 1494.823529, 'orderTotal': 17}), closeTo(25412, 1));
  });

  test('zero gross never falls back to net', () {
    expect(dashboardGrossValue({'grossTotal': 0, 'netTotal': 54236.78}), 0);
  });

  test('multiple rows are aggregated', () {
    final rows = [
      {'grossTotal': 1000, 'netTotal': 900},
      {'grossTotal': 2000, 'netTotal': 1800},
    ];
    expect(dashboardGrossValue(rows), 3000);
  });
}
