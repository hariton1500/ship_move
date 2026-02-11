import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:space_core/world_state.dart';

class SpaceGame extends FlameGame {
  late WorldState gameWorld;

  @override
  Future<void> onLoad() async {
    gameWorld = WorldState();
  }

  @override
  void update(double dt) {
    super.update(dt);

    // Используйте gameWorld для обновления логики PvP и состояния игры
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);

    // Используйте gameWorld для рендеринга игрового мира и объектов
  }
}
