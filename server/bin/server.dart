import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:space_core/core.dart';
import 'package:space_core/systems/movement_system.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const int teamShipLimit = 10;
const int teamPointsLimit = 100;
const int balanceDeltaLimit = 10;
const int defaultShipPoints = 10;
const int matchmakingIntervalSeconds = 5;
const int matchDurationSeconds = 10 * 60;

final tickEngine = TickEngine(20);
final world = WorldState();
final movementSystem = MovementSystem();
final commandQueue = <Command>[];
final accounts = <String, String>{};
final sessionsByChannel = <WebSocketChannel, PlayerSession>{};
final waitingRandom = <PlayerSession>[];
final waitingTournament = <PlayerSession>[];
final shipOwnerById = <int, PlayerSession>{};
final shipTeamById = <int, String>{};
final shipPointsById = <int, int>{};
final _rng = math.Random();

ActiveMatch? activeMatch;
int _nextMatchId = 1;
int _nextShipId = 1;

void main() async {
  final handler = webSocketHandler((WebSocketChannel channel) {
    final session = PlayerSession(channel: channel);
    sessionsByChannel[channel] = session;
    _send(channel, {'type': 'hello', 'msg': 'connected'});
    _broadcastQueueStatus();

    channel.stream.listen(
      (message) {
        try {
          final data = jsonDecode(message as String);
          if (data is! Map) return;
          _handleIncomingMessage(session, Map<String, dynamic>.from(data));
        } catch (e) {
          _send(channel, {'type': 'error', 'reason': 'invalid_json'});
        }
      },
      onDone: () {
        _handleDisconnect(session);
      },
    );
  });

  final server = await io.serve(handler, '0.0.0.0', 8080);
  print('Server running on ws://${server.address.host}:${server.port}');

  Timer.periodic(const Duration(milliseconds: 50), (_) {
    tickEngine.update(0.05, (dt) {
      _processCommands();
      movementSystem.update(world, dt);
      _clampShipsToArena();
      _updateMatchLifecycle();
      _broadcastState();
    });
  });

  Timer.periodic(
    const Duration(seconds: matchmakingIntervalSeconds),
    (_) => _runMatchmaking(),
  );
}

void _handleIncomingMessage(PlayerSession session, Map<String, dynamic> data) {
  final type = data['type'] as String?;
  if (type == null) return;
  switch (type) {
    case 'register':
    case 'login':
      _handleAuthMessage(session, type, data);
      break;
    case 'queue_join':
      _handleQueueJoin(session, data);
      break;
    case 'queue_leave':
      _handleQueueLeave(session);
      break;
    case 'move':
    case 'orbit':
      _handlePilotCommand(session, type, data);
      break;
    default:
      _send(session.channel, {
        'type': 'error',
        'reason': 'unknown_type',
        'messageType': type,
      });
      break;
  }
}

void _handleAuthMessage(
  PlayerSession session,
  String type,
  Map<String, dynamic> data,
) {
  final email = (data['email'] as String? ?? '').trim().toLowerCase();
  final password = data['password'] as String? ?? '';
  if (email.isEmpty || password.isEmpty) {
    _send(session.channel, {
      'type': 'auth',
      'action': type,
      'ok': false,
      'reason': 'email_or_password_empty',
    });
    return;
  }

  if (type == 'register') {
    if (accounts.containsKey(email)) {
      _send(session.channel, {
        'type': 'auth',
        'action': 'register',
        'ok': false,
        'reason': 'already_exists',
      });
      return;
    }
    accounts[email] = password;
    session
      ..authenticated = true
      ..email = email;
    _send(session.channel, {'type': 'auth', 'action': 'register', 'ok': true});
    return;
  }

  final ok = accounts[email] == password;
  if (ok) {
    session
      ..authenticated = true
      ..email = email;
  }
  _send(session.channel, {
    'type': 'auth',
    'action': 'login',
    'ok': ok,
    if (!ok) 'reason': 'invalid_credentials',
  });
}

void _handleQueueJoin(PlayerSession session, Map<String, dynamic> data) {
  if (!session.authenticated) {
    _send(session.channel, {
      'type': 'queue',
      'action': 'join',
      'ok': false,
      'reason': 'not_authenticated',
    });
    return;
  }
  if (session.matchId != null) {
    _send(session.channel, {
      'type': 'queue',
      'action': 'join',
      'ok': false,
      'reason': 'already_in_match',
    });
    return;
  }

  final mode = (data['mode'] as String? ?? '').trim().toLowerCase();
  if (mode != 'random' && mode != 'tournament') {
    _send(session.channel, {
      'type': 'queue',
      'action': 'join',
      'ok': false,
      'reason': 'invalid_mode',
    });
    return;
  }

  final pointsRaw = data['shipPoints'];
  final points = _parsePoints(pointsRaw);

  _removeFromQueues(session);
  session
    ..queueMode = mode
    ..shipPoints = points;
  _queueForMode(mode).add(session);

  _send(session.channel, {
    'type': 'queue',
    'action': 'join',
    'ok': true,
    'mode': mode,
    'shipPoints': points,
  });
  _broadcastQueueStatus();
}

void _handleQueueLeave(PlayerSession session) {
  _removeFromQueues(session);
  _send(session.channel, {'type': 'queue', 'action': 'leave', 'ok': true});
  _broadcastQueueStatus();
}

void _handlePilotCommand(
  PlayerSession session,
  String type,
  Map<String, dynamic> data,
) {
  if (session.matchId == null ||
      activeMatch == null ||
      activeMatch!.id != session.matchId ||
      session.shipId == null) {
    return;
  }

  final shipId = session.shipId!;
  if (type == 'move') {
    final x = (data['x'] as num?)?.toDouble();
    final y = (data['y'] as num?)?.toDouble();
    if (x == null || y == null) return;
    commandQueue.add(MoveCommand(shipId, x, y));
    return;
  }

  final targetId = data['targetId'] as int?;
  final radius = (data['radius'] as num?)?.toDouble();
  if (targetId == null || radius == null) return;
  commandQueue.add(OrbitCommand(shipId, targetId, radius));
}

void _processCommands() {
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

void _runMatchmaking() {
  if (activeMatch != null) return;

  final modes = <String>['random', 'tournament'];
  for (final mode in modes) {
    final queue = _queueForMode(mode);
    if (queue.length < 2) continue;

    final teams = _buildTeams(queue);
    if (teams == null) continue;

    for (final p in teams.teamA) {
      queue.remove(p);
    }
    for (final p in teams.teamB) {
      queue.remove(p);
    }

    _startMatch(
      mode: mode,
      teamA: teams.teamA,
      teamB: teams.teamB,
      pointsA: teams.pointsA,
      pointsB: teams.pointsB,
    );
    _broadcastQueueStatus();
    return;
  }
}

TeamsBuildResult? _buildTeams(List<PlayerSession> waiting) {
  final candidates = waiting.toList(growable: false)
    ..sort((a, b) => b.shipPoints.compareTo(a.shipPoints));

  final teamA = <PlayerSession>[];
  final teamB = <PlayerSession>[];
  var pointsA = 0;
  var pointsB = 0;

  for (final player in candidates) {
    final p = player.shipPoints;
    final canA =
        teamA.length < teamShipLimit && (pointsA + p) <= teamPointsLimit;
    final canB =
        teamB.length < teamShipLimit && (pointsB + p) <= teamPointsLimit;
    if (!canA && !canB) continue;

    if (canA && canB) {
      if (pointsA < pointsB ||
          (pointsA == pointsB && teamA.length <= teamB.length)) {
        teamA.add(player);
        pointsA += p;
      } else {
        teamB.add(player);
        pointsB += p;
      }
      continue;
    }

    if (canA) {
      teamA.add(player);
      pointsA += p;
    } else {
      teamB.add(player);
      pointsB += p;
    }
  }

  if (teamA.isEmpty || teamB.isEmpty) return null;
  if ((pointsA - pointsB).abs() > balanceDeltaLimit) return null;
  return TeamsBuildResult(teamA, teamB, pointsA, pointsB);
}

void _startMatch({
  required String mode,
  required List<PlayerSession> teamA,
  required List<PlayerSession> teamB,
  required int pointsA,
  required int pointsB,
}) {
  world.ships.clear();
  commandQueue.clear();
  shipOwnerById.clear();
  shipTeamById.clear();
  shipPointsById.clear();

  final id = _nextMatchId++;
  final now = DateTime.now();
  activeMatch = ActiveMatch(
    id: id,
    mode: mode,
    startedAt: now,
    endsAt: now.add(const Duration(seconds: matchDurationSeconds)),
    teamA: teamA,
    teamB: teamB,
    initialPointsA: pointsA,
    initialPointsB: pointsB,
  );

  for (final s in teamA) {
    _assignShipToPlayer(s, 'A');
  }
  for (final s in teamB) {
    _assignShipToPlayer(s, 'B');
  }

  for (final s in [...teamA, ...teamB]) {
    _send(s.channel, {
      'type': 'match_started',
      'matchId': id,
      'mode': mode,
      'team': s.team,
      'shipId': s.shipId,
      'durationSec': matchDurationSeconds,
      'teamSizeA': teamA.length,
      'teamSizeB': teamB.length,
      'teamPointsA': pointsA,
      'teamPointsB': pointsB,
    });
  }
}

void _assignShipToPlayer(PlayerSession session, String team) {
  final shipId = _nextShipId++;
  session
    ..shipId = shipId
    ..team = team
    ..matchId = activeMatch!.id
    ..queueMode = null;

  world.addShip(ShipModel(id: shipId, position: _randomSpawnPosition()));
  shipOwnerById[shipId] = session;
  shipTeamById[shipId] = team;
  shipPointsById[shipId] = session.shipPoints;
}

void _updateMatchLifecycle() {
  final match = activeMatch;
  if (match == null) return;

  final aliveA = _alivePoints('A');
  final aliveB = _alivePoints('B');
  if (aliveA <= 0 || aliveB <= 0) {
    final winner = aliveA > aliveB ? 'A' : (aliveB > aliveA ? 'B' : 'draw');
    _finishMatch(winner: winner, reason: 'team_destroyed');
    return;
  }

  final now = DateTime.now();
  if (!now.isBefore(match.endsAt)) {
    final winner = aliveA > aliveB ? 'A' : (aliveB > aliveA ? 'B' : 'draw');
    _finishMatch(winner: winner, reason: 'timer');
  }
}

void _finishMatch({required String winner, required String reason}) {
  final match = activeMatch;
  if (match == null) return;

  final scoreA = _alivePoints('A');
  final scoreB = _alivePoints('B');
  final participants = [...match.teamA, ...match.teamB];

  for (final s in participants) {
    _send(s.channel, {
      'type': 'match_ended',
      'matchId': match.id,
      'winner': winner,
      'reason': reason,
      'scoreA': scoreA,
      'scoreB': scoreB,
    });
    s
      ..matchId = null
      ..team = null
      ..shipId = null;
  }

  world.ships.clear();
  commandQueue.clear();
  shipOwnerById.clear();
  shipTeamById.clear();
  shipPointsById.clear();
  activeMatch = null;
}

int _alivePoints(String team) {
  var sum = 0;
  for (final shipId in world.ships.keys) {
    if (shipTeamById[shipId] == team) {
      sum += shipPointsById[shipId] ?? 0;
    }
  }
  return sum;
}

void _broadcastState() {
  final match = activeMatch;
  if (match == null) return;

  final now = DateTime.now();
  final remainingSec = match.endsAt
      .difference(now)
      .inSeconds
      .clamp(0, matchDurationSeconds);
  final snapshot = world.ships.values
      .map(
        (s) => {
          'id': s.id,
          'team': shipTeamById[s.id],
          'points': shipPointsById[s.id],
          'faction': s.faction.name,
          'class': s.shipClass.name,
          'hull': s.hullName.name,
          'x': s.position.x,
          'y': s.position.y,
          'vx': s.velocity.x,
          'vy': s.velocity.y,
        },
      )
      .toList(growable: false);

  final msg = {
    'type': 'state',
    'matchId': match.id,
    'remainingSec': remainingSec,
    'ships': snapshot,
  };
  for (final s in [...match.teamA, ...match.teamB]) {
    _send(s.channel, msg);
  }
}

void _broadcastQueueStatus() {
  final msg = {
    'type': 'queue_status',
    'randomWaiting': waitingRandom.length,
    'tournamentWaiting': waitingTournament.length,
    'matchActive': activeMatch != null,
  };
  for (final session in sessionsByChannel.values) {
    _send(session.channel, msg);
  }
}

void _handleDisconnect(PlayerSession session) {
  sessionsByChannel.remove(session.channel);
  _removeFromQueues(session);

  if (session.shipId != null) {
    world.ships.remove(session.shipId!);
    shipOwnerById.remove(session.shipId!);
    shipTeamById.remove(session.shipId!);
    shipPointsById.remove(session.shipId!);
  }

  if (activeMatch != null && session.matchId == activeMatch!.id) {
    _updateMatchLifecycle();
  }

  _broadcastQueueStatus();
}

void _removeFromQueues(PlayerSession session) {
  waitingRandom.remove(session);
  waitingTournament.remove(session);
  session.queueMode = null;
}

List<PlayerSession> _queueForMode(String mode) {
  return mode == 'tournament' ? waitingTournament : waitingRandom;
}

int _parsePoints(dynamic raw) {
  final parsed = (raw as num?)?.toInt() ?? defaultShipPoints;
  return parsed.clamp(1, teamPointsLimit);
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

void _send(WebSocketChannel channel, Map<String, dynamic> payload) {
  channel.sink.add(jsonEncode(payload));
}

class PlayerSession {
  final WebSocketChannel channel;
  bool authenticated = false;
  String? email;
  String? queueMode;
  int shipPoints = defaultShipPoints;
  int? matchId;
  int? shipId;
  String? team;

  PlayerSession({required this.channel});
}

class ActiveMatch {
  final int id;
  final String mode;
  final DateTime startedAt;
  final DateTime endsAt;
  final List<PlayerSession> teamA;
  final List<PlayerSession> teamB;
  final int initialPointsA;
  final int initialPointsB;

  ActiveMatch({
    required this.id,
    required this.mode,
    required this.startedAt,
    required this.endsAt,
    required this.teamA,
    required this.teamB,
    required this.initialPointsA,
    required this.initialPointsB,
  });
}

class TeamsBuildResult {
  final List<PlayerSession> teamA;
  final List<PlayerSession> teamB;
  final int pointsA;
  final int pointsB;

  TeamsBuildResult(this.teamA, this.teamB, this.pointsA, this.pointsB);
}
