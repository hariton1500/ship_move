import 'package:vector_math/vector_math_64.dart';

class ShipModel {
  final int id;

  Vector2 position;
  Vector2 velocity = Vector2.zero();

  int? orbitTarget;
  double orbitRadius = 0;

  ShipModel({
    required this.id,
    required this.position,
  });
}
