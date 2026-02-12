import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
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
final accounts = <String, String>{};

void main() async {
  world.addShip(ShipModel(id: 1, position: _randomSpawnPosition()));
  world.addShip(ShipModel(id: 2, position: _randomSpawnPosition()));

  final handler = webSocketHandler((WebSocketChannel channel) {
    print('Client connected');
    clients.add(channel);

    channel.stream.listen(
      (message) {
        try {
          final data = jsonDecode(message as String);
          handleIncomingMessage(channel, data);
        } catch (e) {
          print('Invalid command: $e');
        }
      },
      onDone: () {
        clients.remove(channel);
        print('Client disconnected');
      },
    );
  });

  final server = await io.serve(handler, '0.0.0.0', 8080);
  print('Server running on ws://${server.address.host}:${server.port}');

  Timer.periodic(const Duration(milliseconds: 50), (_) {
    tickEngine.update(0.05, (dt) {
      processCommands();
      movementSystem.update(world, dt);
      _clampShipsToArena();
      broadcastState();
    });
  });
}

void handleIncomingMessage(
  WebSocketChannel channel,
  Map<String, dynamic> data,
) {
  final type = data['type'];
  if (type == 'register' || type == 'login') {
    _handleAuthMessage(channel, data);
    return;
  }

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

void _handleAuthMessage(WebSocketChannel channel, Map<String, dynamic> data) {
  final type = data['type'] as String?;
  final email = (data['email'] as String? ?? '').trim().toLowerCase();
  final password = data['password'] as String? ?? '';

  if (email.isEmpty || password.isEmpty) {
    channel.sink.add(
      jsonEncode({
        'type': 'auth',
        'action': type,
        'ok': false,
        'reason': 'email_or_password_empty',
      }),
    );
    return;
  }

  if (type == 'register') {
    if (accounts.containsKey(email)) {
      channel.sink.add(
        jsonEncode({
          'type': 'auth',
          'action': 'register',
          'ok': false,
          'reason': 'already_exists',
        }),
      );
      return;
    }
    accounts[email] = password;
    channel.sink.add(
      jsonEncode({'type': 'auth', 'action': 'register', 'ok': true}),
    );
    return;
  }

  final ok = accounts[email] == password;
  channel.sink.add(
    jsonEncode({
      'type': 'auth',
      'action': 'login',
      'ok': ok,
      if (!ok) 'reason': 'invalid_credentials',
    }),
  );
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
      .map(
        (s) => {
          'id': s.id,
          'faction': s.faction.name,
          'class': s.shipClass.name,
          'hull': s.hullName.name,
          'x': s.position.x,
          'y': s.position.y,
          'vx': s.velocity.x,
          'vy': s.velocity.y,
          'orbitTarget': s.orbitTarget,
          'orbitRadius': s.orbitRadius,
        },
      )
      .toList();
  final msg = jsonEncode({'ships': snapshot});
  for (final ws in clients) {
    ws.sink.add(msg);
  }
}

void _clampShipsToArena() {
  for (final ship in world.ships.values) {
    final clamped = BattleRules.clampToArena(ship.position);
    final isOnEdge = (clamped - ship.position).length2 > 1e-9;
    ship.position = clamped;
    if (isOnEdge) {
      ship.velocity.setZero();
    }
  }
}

Vector2 _randomSpawnPosition() {
  final angle = _rng.nextDouble() * math.pi * 2;
  final radius = BattleRules.arenaRadiusMeters * math.sqrt(_rng.nextDouble());
  return Vector2(
    BattleRules.arenaCenter.x + math.cos(angle) * radius,
    BattleRules.arenaCenter.y + math.sin(angle) * radius,
  );
}

final _rng = math.Random();
