import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/features/reader/curl_sheet.dart';

void main() {
  test('the visible front bends before the roll reaches it', () {
    final sheet = CurlSheet(600, .25);
    final a = sheet.point(sheet.start + sheet.frontReach * .25);
    final b = sheet.point(sheet.start + sheet.frontReach * .75);
    expect(sheet.point(sheet.start * .5).z, 0);
    expect(a.z, greaterThan(0));
    expect(b.z, greaterThan(a.z));
    expect(b.angle, greaterThan(a.angle));
    expect(b.x, lessThan(sheet.start + sheet.frontReach * .75));
  });
  test('front, roll and back join without a crease or stretching', () {
    for (final p in [.01, .25, .5, .75, .99]) {
      for (final cone in [.7, 1.0, 1.3]) {
        final sheet = CurlSheet(600, p, cone: cone);
        for (final join in [sheet.start, sheet.front, sheet.end]) {
          const e = .0001;
          final a = sheet.point(join - e), b = sheet.point(join + e);
          expect((a.x - b.x).abs(), lessThan(.0003));
          expect((a.z - b.z).abs(), lessThan(.0003));
          expect((a.angle - b.angle).abs(), lessThan(.001));
          final distance = math.sqrt(
            math.pow(a.x - b.x, 2) + math.pow(a.z - b.z, 2),
          );
          expect(distance, closeTo(2 * e, .000001));
        }
      }
    }
  });
}
