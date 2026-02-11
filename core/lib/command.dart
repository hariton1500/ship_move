abstract class Command {
  final int shipId;
  Command(this.shipId);
}

class MoveCommand extends Command {
  final double x;
  final double y;

  MoveCommand(super.shipId, this.x, this.y);
}

class OrbitCommand extends Command {
  final int targetId;
  final double radius;

  OrbitCommand(super.shipId, this.targetId, this.radius);
}
