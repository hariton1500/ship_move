import 'package:vector_math/vector_math_64.dart';
import 'battle_rules.dart';

class ShipModel {
  final int id;
  final Faction faction;
  final ShipClass shipClass;
  final HullName hullName;

  Vector2 position;
  Vector2 velocity = Vector2.zero();

  int? orbitTarget;
  double orbitRadius = 0;

  ShipModel({
    required this.id,
    required this.position,
    this.faction = Faction.gals,
    this.shipClass = ShipClass.frigate,
    this.hullName = HullName.atron,
  });
}
