import 'dart:async';
import 'dart:convert';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:space_core/systems/movement_system.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:space_core/core.dart';
import 'package:vector_math/vector_math_64.dart';


final world = WorldState();
final tickEngine = TickEngine(20);
final movementSystem = MovementSystem();
final clients = <WebSocketChannel>{};
final commandQueue = <Command>[];

void main() async {
  world.addShip(ShipModel(id: 1, position: Vector2(1000, 1000)));
  world.addShip(ShipModel(id: 2, position: Vector2(5000, 5000)));

  final handler = webSocketHandler((WebSocketChannel channel) {
    print('Client connected');
    clients.add(channel);

    channel.stream.listen((message) {
      try {
        final data = jsonDecode(message as String);
        handleIncomingCommand(data);
      } catch (e) {
        print('Invalid command: $e');
      }
    }, onDone: () {
      clients.remove(channel);
      print('Client disconnected');
    });
  });

  final server = await io.serve(handler, '0.0.0.0', 8080);
  print('Server running on ws://${server.address.host}:${server.port}');

  Timer.periodic(const Duration(milliseconds: 50), (_) {
    tickEngine.update(0.05, (dt) {
      processCommands();
      movementSystem.update(world, dt);
      broadcastState();
    });
  });
}

void handleIncomingCommand(Map<String, dynamic> data) {
  final type = data['type'];
  final shipId = data['shipId'] as int;
  switch (type) {
    case 'move':
      final x = data['x'] as double;
      final y = data['y'] as double;
      commandQueue.add(MoveCommand(shipId, x, y));
      break;
    case 'orbit':
      final targetId = data['targetId'] as int;
      final radius = data['radius'] as double;
      commandQueue.add(OrbitCommand(shipId, targetId, radius));
      break;
    default:
      print('Unknown command type: $type');
  }
}

void processCommands() {
  for (final cmd in commandQueue) {
    final ship = world.ships[cmd.shipId];
    if (ship == null) continue;

    if (cmd is MoveCommand) {
      final target = Vector2(cmd.x, cmd.y);
      ship.velocity = (target - ship.position).normalized() * 100.0;
    } else if (cmd is OrbitCommand) {
      ship.orbitTarget = cmd.targetId;
      ship.orbitRadius = cmd.radius;
    }
  }
  commandQueue.clear();
}

void broadcastState() {
  final snapshot = world.ships.values
      .map((s) => {
            'id': s.id,
            'x': s.position.x,
            'y': s.position.y,
            'vx': s.velocity.x,
            'vy': s.velocity.y,
            'orbitTarget': s.orbitTarget,
            'orbitRadius': s.orbitRadius,
          })
      .toList();
  final msg = jsonEncode({'ships': snapshot});
  for (final ws in clients) {
    ws.sink.add(msg);
  }
}