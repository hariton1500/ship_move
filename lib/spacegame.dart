import 'dart:math' as math;
import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:ship_move/shipcomponent.dart';

class SpaceGame extends FlameGame with DoubleTapDetector, ScrollDetector, PanDetector {
  late ShipComponent player, point;
  double _targetZoom = 1.0;
  final double _minZoom = 0.5;
  final double _maxZoom = 2.5;
  final double _zoomResponse = 10.0; // больше = резче

  @override
  Future<void> onLoad() async {
    player = ShipComponent()
      ..position = Vector2(100, 100);

    world.add(player);

    camera.viewfinder.anchor = Anchor.center;

    point = ShipComponent()..position = Vector2(500, 500);
    world.add(point);
  }

  @override
  void onScroll(PointerScrollInfo info) {
    final delta = info.scrollDelta.global.y;
    final factor = 1 - delta * 0.001;
    _targetZoom = (_targetZoom * factor).clamp(_minZoom, _maxZoom);
  }

  @override
  void update(double dt) {
    super.update(dt);
    final current = camera.viewfinder.zoom;
    final t = 1 - math.exp(-_zoomResponse * dt);
    camera.viewfinder.zoom = current + (_targetZoom - current) * t;
  }

  @override
  void onPanUpdate(DragUpdateInfo info) {
    final delta = info.delta.global;
    final zoom = camera.viewfinder.zoom;
    camera.viewfinder.position -= delta / zoom;
  }

  @override
  void onDoubleTapDown(TapDownInfo info) {
    final worldPos = camera.globalToLocal(info.eventPosition.widget);
    player.moveTo(worldPos);
  }
}
