import 'dart:math' as math;
import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flame/experimental.dart';
import 'package:flutter/material.dart';
import 'package:ship_move/shipcomponent.dart';

// Основной игровой класс: камера, ввод и логика сцены.
class SpaceGame extends FlameGame with DoubleTapDetector, ScrollDetector, PanDetector {
  late ShipComponent player, point;
  late TextComponent _zoomHud; // отладочный HUD
  bool _shipsReady = false; // защита от доступа до onLoad
  static const double worldSizeMeters = 100000; // размер мира
  double _targetZoom = 1.0; // целевой зум
  final double _minZoom = 0.1; // ограничения зума
  final double _maxZoom = 1;
  final double _zoomResponse = 10.0; // больше = резче
  final double _fitPadding = 200.0; // поля вокруг кораблей при автоподгонке

  @override
  Future<void> onLoad() async {
    // Ограничиваем камеру рамками мира.
    camera.setBounds(
      Rectangle.fromLTWH(0, 0, worldSizeMeters, worldSizeMeters),
      considerViewport: true,
    );

    // Создаем игрока.
    player = ShipComponent()
      ..position = Vector2(50000, 50000);

    world.add(player);

    // Настраиваем камеру.
    camera.viewfinder.anchor = Anchor.center;
    camera.viewfinder.zoom = _targetZoom;

    // Вторая точка/корабль для теста.
    point = ShipComponent()..position = Vector2(60000, 60000);
    world.add(point);

    _shipsReady = true;
    _fitToShips();

    // HUD с диагностикой.
    _zoomHud = TextComponent(
      text: 'zoom: ${camera.viewfinder.zoom.toStringAsFixed(2)}',
      position: Vector2(8, 8),
      anchor: Anchor.topLeft,
      textRenderer: TextPaint(
        style: const TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 14,
        ),
      ),
    );
    camera.viewport.add(_zoomHud);
  }

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    // При изменении размера экрана пересчитываем камеру.
    if (!_shipsReady) return;
    _fitToShips();
  }

  void _fitToShips() {
    // Подгоняем камеру так, чтобы все корабли были видны.
    if (!_shipsReady) {
      return;
    }
    final viewportSize = camera.viewport.virtualSize;
    if (viewportSize.x == 0 || viewportSize.y == 0) {
      return;
    }
    camera.stop();

    final ships = [player, point];
    // Находим границы всех кораблей.
    double minX = ships.first.position.x;
    double maxX = ships.first.position.x;
    double minY = ships.first.position.y;
    double maxY = ships.first.position.y;

    for (final s in ships) {
      minX = math.min(minX, s.position.x);
      maxX = math.max(maxX, s.position.x);
      minY = math.min(minY, s.position.y);
      maxY = math.max(maxY, s.position.y);
    }

    final width = (maxX - minX) + _fitPadding * 2;
    final height = (maxY - minY) + _fitPadding * 2;
    final center = Vector2((minX + maxX) * 0.5, (minY + maxY) * 0.5);

    // Выбираем зум по меньшей из осей.
    final zoomX = viewportSize.x / width;
    final zoomY = viewportSize.y / height;
    _targetZoom = math.min(zoomX, zoomY).clamp(_minZoom, _maxZoom);
    camera.viewfinder.zoom = _targetZoom;
    camera.viewfinder.position = center;
  }

  @override
  void onScroll(PointerScrollInfo info) {
    // Колесико мыши: меняем целевой зум.
    final delta = info.scrollDelta.global.y;
    final factor = 1 - delta * 0.001;
    _targetZoom = (_targetZoom * factor).clamp(_minZoom, _maxZoom);
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (!_shipsReady) return;
    // Плавно двигаем зум к цели.
    final current = camera.viewfinder.zoom;
    final t = 1 - math.exp(-_zoomResponse * dt);
    camera.viewfinder.zoom = current + (_targetZoom - current) * t;
    // Диагностика координат.
    final pWorld = player.position;
    final qWorld = point.position;
    final pScreen = camera.localToGlobal(pWorld);
    final qScreen = camera.localToGlobal(qWorld);
    _zoomHud.text = [
      'zoom: ${camera.viewfinder.zoom.toStringAsFixed(2)}',
      'player world: ${pWorld.x.toStringAsFixed(1)}, ${pWorld.y.toStringAsFixed(1)}',
      'player screen: ${pScreen.x.toStringAsFixed(1)}, ${pScreen.y.toStringAsFixed(1)}',
      'point world: ${qWorld.x.toStringAsFixed(1)}, ${qWorld.y.toStringAsFixed(1)}',
      'point screen: ${qScreen.x.toStringAsFixed(1)}, ${qScreen.y.toStringAsFixed(1)}',
    ].join('\n');
  }

  @override
  void onPanUpdate(DragUpdateInfo info) {
    // Перетаскивание: сдвиг камеры.
    final delta = info.delta.global;
    final zoom = camera.viewfinder.zoom;
    camera.viewfinder.position -= delta / zoom;
  }

  @override
  void onDoubleTapDown(TapDownInfo info) {
    // Двойной тап: задать цель игроку.
    final worldPos = camera.globalToLocal(info.eventPosition.widget);
    player.moveTo(worldPos);
  }
}
