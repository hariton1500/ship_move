import 'dart:math';
import 'package:flame/components.dart';
import 'package:flutter/material.dart';

// Компонент корабля: треугольник + простая физика движения.
class ShipComponent extends PositionComponent with HasGameReference {
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

  // Задать цель в мировых координатах.
  void moveTo(Vector2 worldTarget) {
    target = worldTarget.clone();
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    final w = size.x;
    final h = size.y;
    // Минимум 10px на экране независимо от зума.
    final zoom = game.camera.viewfinder.zoom;
    final minDim = min(w, h);
    final minScreenPx = 10.0;
    final scale = max(1.0, minScreenPx / (minDim * zoom));
    if (scale != 1.0) {
      canvas.save();
      canvas.translate(w * 0.5, h * 0.5);
      canvas.scale(scale);
      canvas.translate(-w * 0.5, -h * 0.5);
    }
    final path = Path()
      ..moveTo(w * 0.5, 0)
      ..lineTo(0, h)
      ..lineTo(w, h)
      //..lineTo(w, 0)
      ..close();
    canvas.drawPath(path, _paint);
    if (scale != 1.0) {
      canvas.restore();
    }
  }

  @override
  void update(double dt) {
    super.update(dt);

    if (target == null) return;

    // Вектор к цели и расстояние.
    final toTarget = target! - position;
    final distance = toTarget.length;

    if (distance < 5 && velocity.length < 10) {
      // Достигли цели.
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
      // Ускоряемся в направлении носа.
      final forward = Vector2(cos(angleRad), sin(angleRad));
      velocity += forward * acceleration * dt;
    } else {
      // Мягко тормозим.
      velocity *= 0.95; // мягкое торможение
    }

    if (velocity.length > maxSpeed) {
      velocity.scaleTo(maxSpeed);
    }

    // Применяем движение и угол.
    position += velocity * dt;
    angle = angleRad;
  }

  // Угол кратчайшего поворота.
  double _shortestAngle(double a, double b) {
    double diff = (b - a + pi) % (2 * pi) - pi;
    return diff < -pi ? diff + 2 * pi : diff;
  }
}
