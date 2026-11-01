import 'package:flutter/physics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/features/reader/motion_timing.dart';

void main() {
  test('late first frame and stalls do not skip through a page turn', () {
    final motion = ReaderMotionSimulation(
      0,
      1,
      const Duration(milliseconds: 400),
    );
    expect(motion.x(2), 0);
    expect(motion.x(2.016), lessThan(.002));
    final delayed = motion.x(2.250);
    expect(delayed, lessThan(.02));
    expect(motion.isDone(2.250), isFalse);
    var previous = delayed;
    for (var i = 1; i <= 25; i++) {
      final value = motion.x(2.250 + i * .016);
      expect(value, inInclusiveRange(previous, 1));
      previous = value;
    }
    expect(previous, 1);
    expect(motion.dx(3), 0);
    expect(motion.isDone(3), isTrue);
  });
  test(
    'released page inherits velocity and eases to rest without overshoot',
    () {
      final motion = ReaderMotionSimulation(
        .4,
        1,
        const Duration(milliseconds: 240),
        automatic: false,
        velocity: 1.5,
      );
      expect(motion.x(0), .4);
      expect(motion.dx(0), closeTo(1.5, 1e-9));
      var previous = .4;
      for (var i = 1; i <= 20; i++) {
        final value = motion.x(i * .016);
        expect(value, inInclusiveRange(previous, 1));
        previous = value;
      }
      expect(previous, 1);
      expect(motion.dx(.32), 0);
      final returning = ReaderMotionSimulation(
        .4,
        0,
        const Duration(milliseconds: 240),
        automatic: false,
        velocity: -1.5,
      );
      returning.x(0);
      expect(returning.dx(0), closeTo(-1.5, 1e-9));
      expect(returning.x(.016), lessThan(.4));
    },
  );
  test(
    'native page snap preserves its spring through missed render frames',
    () {
      final spring = SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 170, damping: 26),
        0,
        1,
        2,
      );
      final paced = PacedReaderSimulation(spring);
      expect(paced.x(5), spring.x(0));
      expect(paced.x(5.25), closeTo(spring.x(.032), 1e-9));
      expect(paced.dx(5.25), closeTo(spring.dx(.032), 1e-9));
      expect(paced.isDone(5.25), isFalse);
      for (var i = 1; i <= 200; i++) {
        paced.x(5.25 + i * .016);
      }
      expect(paced.isDone(9), isTrue);
    },
  );
}
