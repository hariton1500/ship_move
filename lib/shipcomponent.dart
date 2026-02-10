import 'dart:math';
import 'package:flame/components.dart';
import 'package:flutter/material.dart';

class ShipComponent extends PositionComponent {
  final Paint _paint = Paint()..color = Colors.white;
  // Физика
  Vector2 velocity = Vector2.zero();
  double angleRad = 0;

  // Характеристики корабля
  final double maxSpeed = 300;
  final double acceleration = 200;
  final double turnRate = 4.5; // рад/сек

  // Цель движения
  Vector2? target;

  ShipComponent() {
    anchor = Anchor.center;
    size = Vector2(100, 100);
  }

  void moveTo(Vector2 worldTarget) {
    target = worldTarget.clone();
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    final w = size.x;
    final h = size.y;
    final path = Path()
      ..moveTo(w * 0.5, 0)
      ..lineTo(0, h)
      ..lineTo(w, h)
      //..lineTo(w, 0)
      ..close();
    canvas.drawPath(path, _paint);
  }

  @override
  void update(double dt) {
    super.update(dt);

    if (target == null) return;

    final toTarget = target! - position;
    final distance = toTarget.length;

    if (distance < 5 && velocity.length < 10) {
      velocity.setZero();
      target = null;
      return;
    }

    // ===== ПОВОРОТ =====
    final desiredAngle = atan2(toTarget.y, toTarget.x);
    final delta = _shortestAngle(angleRad, desiredAngle);
    angleRad += delta.clamp(-turnRate * dt, turnRate * dt);

    // ===== ТОРМОЖЕНИЕ =====
    final brakeDistance =
        (velocity.length * velocity.length) / (2 * acceleration);

    if (distance > brakeDistance) {
      final forward = Vector2(cos(angleRad), sin(angleRad));
      velocity += forward * acceleration * dt;
    } else {
      velocity *= 0.95; // мягкое торможение
    }

    if (velocity.length > maxSpeed) {
      velocity.scaleTo(maxSpeed);
    }

    position += velocity * dt;
    angle = angleRad;
  }

  double _shortestAngle(double a, double b) {
    double diff = (b - a + pi) % (2 * pi) - pi;
    return diff < -pi ? diff + 2 * pi : diff;
  }
}
