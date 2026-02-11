import '../world_state.dart';

class MovementSystem {
  void update(WorldState world, double dt) {
    for (final ship in world.ships.values) {
      ship.position += ship.velocity * dt;
    }
  }
}
