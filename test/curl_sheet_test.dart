import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/features/reader/curl_sheet.dart';

void main() {
  test('curl preserves flat front and back scale without perspective zoom', () {
    for (final direction in [-1, 1]) {
      final fold = CurlProjection(
        width: 300,
        height: 500,
        progress: .85,
        hinge: 400,
        originY: 280,
        direction: direction,
      );
      final a = fold.point(400 - direction * 180.0, 100, back: true);
      final b = fold.point(400 - direction * 240.0, 350, back: true);
      expect((a.x - b.x).abs(), closeTo(60, .000001));
      expect(b.y - a.y, closeTo(250, .000001));
      for (final slope in [-.6, 0.0, .6]) {
        final front = CurlProjection(
          width: 300,
          height: 500,
          progress: .1,
          hinge: 400,
          originY: 280,
          direction: direction,
          foldSlope: slope,
        );
        final point = front.point(400 + direction * 20.0, 240);
        expect(point.z, 0);
        expect(point.x, closeTo(400 + direction * 20, .000001));
        expect(point.y, closeTo(240, .000001));
      }
    }
  });
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
