import 'package:vector_math/vector_math_64.dart';

enum Faction {
  gals,
}

enum ShipClass {
  frigate,
}

enum HullName {
  atron,
}

class BattleRules {
  static const double arenaDiameterMeters = 200000.0;
  static const double arenaRadiusMeters = arenaDiameterMeters / 2.0;
  static final Vector2 arenaCenter = Vector2.zero();

  static bool isInsideArena(Vector2 position) {
    return (position - arenaCenter).length <= arenaRadiusMeters;
  }

  static Vector2 clampToArena(Vector2 position) {
    final offset = position - arenaCenter;
    final distance = offset.length;
    if (distance <= arenaRadiusMeters || distance == 0) {
      return position;
    }
    return arenaCenter + (offset / distance) * arenaRadiusMeters;
  }
}
