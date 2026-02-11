import 'ship_model.dart';

class WorldState {
  final Map<int, ShipModel> ships = {};

  void addShip(ShipModel ship) {
    ships[ship.id] = ship;
  }
}
