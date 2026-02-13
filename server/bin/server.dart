import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
const int newPlayerStartingBalance = 100000;
const int newPlayerStartingFreeXp = 20;
const int atronMasteryXpCost = 5;
const int atronShipPrice = 30000;
const String playersStoragePath = 'data/players.json';
const double baseMoveSpeed = 100.0;
const double minDistanceEpsilon = 1e-6;
const double atronShieldHp = 120.0;
const double atronArmorHp = 90.0;
const double atronCapacitor = 100.0;
const double blasterRange = 9000.0;
const double blasterDps = 28.0;
const double railgunRange = 18000.0;
const double railgunDps = 20.0;
const double webRange = 10000.0;
const double webSpeedFactor = 0.5;
const double afterburnerSpeedFactor = 1.6;
const double afterburnerCapUsePerSecond = 8.0;
const Map<String, int> masteryXpCosts = {'atron': atronMasteryXpCost};
const Map<String, int> shipBuyPrices = {'atron': atronShipPrice};
const Map<String, Map<String, int>> hullFittingStats = {
  'atron': {
    'highSlots': 2,
    'midSlots': 2,
    'lowSlots': 2,
    'cpu': 180,
    'power': 120,
  },
};
const List<Map<String, dynamic>> shipCatalog = [
  {'hull': 'atron', 'name': 'Atron', 'class': 'frigate', 'faction': 'gals'},
];
const List<Map<String, dynamic>> moduleCatalog = [
  {
    'id': 'light_blaster_i',
    'name': 'Light Blaster I',
    'slot': 'high',
    'cpu': 25,
    'power': 20,
  },
  {
    'id': 'small_railgun_i',
    'name': 'Small Railgun I',
    'slot': 'high',
    'cpu': 22,
    'power': 18,
  },
  {
    'id': 'afterburner_i',
    'name': '1MN Afterburner I',
    'slot': 'mid',
    'cpu': 18,
    'power': 16,
  },
  {
    'id': 'stasis_web_i',
    'name': 'Stasis Webifier I',
    'slot': 'mid',
    'cpu': 20,
    'power': 8,
  },
  {
    'id': 'damage_control_i',
    'name': 'Damage Control I',
    'slot': 'low',
    'cpu': 14,
    'power': 10,
  },
  {
    'id': 'magnetic_field_stabilizer_i',
    'name': 'Magnetic Field Stabilizer I',
    'slot': 'low',
    'cpu': 16,
    'power': 12,
  },
];

final tickEngine = TickEngine(20);
final world = WorldState();
final movementSystem = MovementSystem();
final commandQueue = <Command>[];
final players = <String, PlayerProfile>{};
final sessionsByChannel = <WebSocketChannel, PlayerSession>{};
final waitingRandom = <PlayerSession>[];
final waitingTournament = <PlayerSession>[];
final shipOwnerById = <int, PlayerSession>{};
final shipTeamById = <int, String>{};
final shipPointsById = <int, int>{};
final shipRuntimeById = <int, ShipRuntimeState>{};
final _rng = math.Random();

ActiveMatch? activeMatch;
int _nextMatchId = 1;
int _nextShipId = 1;

void main() async {
  await _loadPlayersFromDisk();

  final handler = webSocketHandler((WebSocketChannel channel) {
    final session = PlayerSession(channel: channel);
    sessionsByChannel[channel] = session;
    _logInfo('client_connected', {'sid': _sid(session)});
    _send(channel, {'type': 'hello', 'msg': 'connected'});
    _broadcastQueueStatus();

    channel.stream.listen(
      (message) {
        try {
          final data = jsonDecode(message as String);
          if (data is! Map) return;
          _handleIncomingMessage(session, Map<String, dynamic>.from(data));
        } catch (e) {
          _logWarn('invalid_json', {'sid': _sid(session), 'error': '$e'});
          _send(channel, {'type': 'error', 'reason': 'invalid_json'});
        }
      },
      onDone: () {
        _handleDisconnect(session);
      },
    );
  });

  final server = await io.serve(handler, '0.0.0.0', 8080);
  _logInfo('server_started', {
    'host': server.address.host,
    'port': server.port,
    'tickRate': tickEngine.tickRate,
  });

  Timer.periodic(const Duration(milliseconds: 50), (_) {
    tickEngine.update(0.05, (dt) {
      _processCommands();
      movementSystem.update(world, dt);
      _clampShipsToArena();
      _updateCombat(dt);
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
    case 'hangar_get':
      _handleHangarGet(session);
      break;
    case 'mastery_unlock':
      _handleMasteryUnlock(session, data);
      break;
    case 'ship_buy':
      _handleShipBuy(session, data);
      break;
    case 'fitting_get':
      _handleFittingGet(session, data);
      break;
    case 'fitting_install':
      _handleFittingInstall(session, data);
      break;
    case 'fitting_remove':
      _handleFittingRemove(session, data);
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
    case 'module_set':
      _handleModuleSetCommand(session, data);
      break;
    default:
      _logWarn('unknown_message_type', {'sid': _sid(session), 'type': type});
      _send(session.channel, {
        'type': 'error',
        'reason': 'unknown_type',
        'messageType': type,
      });
      break;
  }
}

void _handleHangarGet(PlayerSession session) {
  if (!session.authenticated || session.email == null) {
    _logWarn('hangar_get_denied_not_authenticated', {'sid': _sid(session)});
    _send(session.channel, {
      'type': 'hangar',
      'action': 'get',
      'ok': false,
      'reason': 'not_authenticated',
    });
    return;
  }

  _logInfo('hangar_get', {'sid': _sid(session), 'email': session.email});
  final profile = players[session.email!];
  if (profile == null) {
    _send(session.channel, {
      'type': 'hangar',
      'action': 'get',
      'ok': false,
      'reason': 'player_not_found',
    });
    return;
  }
  _send(session.channel, {
    'type': 'hangar',
    'action': 'get',
    'ok': true,
    'room': 'hangar',
    'ownerEmail': session.email,
    'balance': profile.balance,
    'freeXp': profile.freeXp,
    'faction': Faction.gals.name,
    'ships': profile.hangarShips,
    'masteryCosts': {'atron': atronMasteryXpCost},
    'masteredHulls': profile.masteredHulls,
    'shipCatalog': shipCatalog
        .map((ship) {
          final hull = (ship['hull'] as String).toLowerCase();
          return {
            ...ship,
            'masteryXpCost': masteryXpCosts[hull] ?? 0,
            'shipPrice': shipBuyPrices[hull] ?? 0,
            'mastered': profile.masteredHulls.contains(hull),
          };
        })
        .toList(growable: false),
  });
}

void _handleShipBuy(PlayerSession session, Map<String, dynamic> data) {
  if (!session.authenticated || session.email == null) {
    _send(session.channel, {
      'type': 'shop',
      'action': 'buy',
      'ok': false,
      'reason': 'not_authenticated',
    });
    return;
  }

  final profile = players[session.email!];
  if (profile == null) {
    _send(session.channel, {
      'type': 'shop',
      'action': 'buy',
      'ok': false,
      'reason': 'player_not_found',
    });
    return;
  }

  final hull = (data['hull'] as String? ?? '').trim().toLowerCase();
  final price = shipBuyPrices[hull];
  if (hull.isEmpty || price == null) {
    _send(session.channel, {
      'type': 'shop',
      'action': 'buy',
      'ok': false,
      'reason': 'invalid_hull',
    });
    return;
  }

  if (!profile.masteredHulls.contains(hull)) {
    _send(session.channel, {
      'type': 'shop',
      'action': 'buy',
      'ok': false,
      'reason': 'hull_not_mastered',
      'hull': hull,
    });
    return;
  }

  if (profile.balance < price) {
    _send(session.channel, {
      'type': 'shop',
      'action': 'buy',
      'ok': false,
      'reason': 'not_enough_balance',
      'required': price,
      'balance': profile.balance,
    });
    return;
  }

  profile.balance -= price;
  final shipInstance = _createShipInstance(hull);
  profile.hangarShips.add(shipInstance);
  unawaited(_savePlayersToDisk());
  _logInfo('ship_bought', {
    'email': session.email,
    'hull': hull,
    'price': price,
    'balance': profile.balance,
    'shipId': shipInstance['id'],
  });
  _send(session.channel, {
    'type': 'shop',
    'action': 'buy',
    'ok': true,
    'hull': hull,
    'price': price,
    'balance': profile.balance,
    'ship': shipInstance,
  });
}

Map<String, dynamic> _createShipInstance(String hull) {
  final id = '$hull-${DateTime.now().microsecondsSinceEpoch}';
  if (hull == 'atron') {
    return {
      'id': id,
      'name': 'Atron',
      'class': 'frigate',
      'hull': 'atron',
      'points': defaultShipPoints,
      'fitting': _defaultFittingForHull(hull),
    };
  }
  return {
    'id': id,
    'name': hull,
    'class': 'unknown',
    'hull': hull,
    'points': defaultShipPoints,
    'fitting': _defaultFittingForHull(hull),
  };
}

void _handleFittingGet(PlayerSession session, Map<String, dynamic> data) {
  final player = _requireAuthenticatedPlayer(session, actionType: 'fitting');
  if (player == null) return;
  final profile = player;

  final shipId = (data['shipId'] as String? ?? '').trim();
  if (shipId.isEmpty) {
    _send(session.channel, {
      'type': 'fitting',
      'action': 'get',
      'ok': false,
      'reason': 'ship_id_empty',
    });
    return;
  }

  final ship = _findOwnedShip(profile, shipId);
  if (ship == null) {
    _send(session.channel, {
      'type': 'fitting',
      'action': 'get',
      'ok': false,
      'reason': 'ship_not_found',
    });
    return;
  }

  final hull = (ship['hull'] as String? ?? '').toLowerCase();
  final fitting = _normalizeFitting(
    Map<String, dynamic>.from(ship['fitting'] as Map? ?? const {}),
    hull,
  );
  ship['fitting'] = fitting;

  _send(session.channel, {
    'type': 'fitting',
    'action': 'get',
    'ok': true,
    'ship': ship,
    'hullStats': _hullStatsFor(hull),
    'moduleCatalog': moduleCatalog,
  });
}

void _handleFittingInstall(PlayerSession session, Map<String, dynamic> data) {
  final player = _requireAuthenticatedPlayer(session, actionType: 'fitting');
  if (player == null) return;
  final profile = player;

  final shipId = (data['shipId'] as String? ?? '').trim();
  final moduleId = (data['moduleId'] as String? ?? '').trim().toLowerCase();
  if (shipId.isEmpty || moduleId.isEmpty) {
    _send(session.channel, {
      'type': 'fitting',
      'action': 'install',
      'ok': false,
      'reason': 'invalid_payload',
    });
    return;
  }

  final ship = _findOwnedShip(profile, shipId);
  if (ship == null) {
    _send(session.channel, {
      'type': 'fitting',
      'action': 'install',
      'ok': false,
      'reason': 'ship_not_found',
    });
    return;
  }

  final module = _moduleById(moduleId);
  if (module == null) {
    _send(session.channel, {
      'type': 'fitting',
      'action': 'install',
      'ok': false,
      'reason': 'module_not_found',
    });
    return;
  }

  final hull = (ship['hull'] as String? ?? '').toLowerCase();
  final stats = _hullStatsFor(hull);
  final fitting = _normalizeFitting(
    Map<String, dynamic>.from(ship['fitting'] as Map? ?? const {}),
    hull,
  );
  final slot = module['slot'] as String;
  final slotList = (fitting[slot] as List).cast<String>();
  final maxSlots = stats['${slot}Slots'] ?? 0;
  if (slotList.length >= maxSlots) {
    _send(session.channel, {
      'type': 'fitting',
      'action': 'install',
      'ok': false,
      'reason': 'slot_full',
      'slot': slot,
    });
    return;
  }

  final usedCpu = (fitting['usedCpu'] as int?) ?? 0;
  final usedPower = (fitting['usedPower'] as int?) ?? 0;
  final needCpu = (module['cpu'] as int?) ?? 0;
  final needPower = (module['power'] as int?) ?? 0;
  final maxCpu = stats['cpu'] ?? 0;
  final maxPower = stats['power'] ?? 0;
  if ((usedCpu + needCpu) > maxCpu || (usedPower + needPower) > maxPower) {
    _send(session.channel, {
      'type': 'fitting',
      'action': 'install',
      'ok': false,
      'reason': 'resources_exceeded',
      'usedCpu': usedCpu,
      'usedPower': usedPower,
      'maxCpu': maxCpu,
      'maxPower': maxPower,
    });
    return;
  }

  slotList.add(moduleId);
  fitting['usedCpu'] = usedCpu + needCpu;
  fitting['usedPower'] = usedPower + needPower;
  ship['fitting'] = fitting;
  unawaited(_savePlayersToDisk());

  _send(session.channel, {
    'type': 'fitting',
    'action': 'install',
    'ok': true,
    'ship': ship,
  });
}

void _handleFittingRemove(PlayerSession session, Map<String, dynamic> data) {
  final player = _requireAuthenticatedPlayer(session, actionType: 'fitting');
  if (player == null) return;
  final profile = player;

  final shipId = (data['shipId'] as String? ?? '').trim();
  final slot = (data['slot'] as String? ?? '').trim().toLowerCase();
  final index = (data['index'] as num?)?.toInt();
  if (shipId.isEmpty ||
      (slot != 'high' && slot != 'mid' && slot != 'low') ||
      index == null) {
    _send(session.channel, {
      'type': 'fitting',
      'action': 'remove',
      'ok': false,
      'reason': 'invalid_payload',
    });
    return;
  }

  final ship = _findOwnedShip(profile, shipId);
  if (ship == null) {
    _send(session.channel, {
      'type': 'fitting',
      'action': 'remove',
      'ok': false,
      'reason': 'ship_not_found',
    });
    return;
  }

  final hull = (ship['hull'] as String? ?? '').toLowerCase();
  final fitting = _normalizeFitting(
    Map<String, dynamic>.from(ship['fitting'] as Map? ?? const {}),
    hull,
  );
  final slotList = (fitting[slot] as List).cast<String>();
  if (index < 0 || index >= slotList.length) {
    _send(session.channel, {
      'type': 'fitting',
      'action': 'remove',
      'ok': false,
      'reason': 'index_out_of_range',
    });
    return;
  }

  final removedModuleId = slotList.removeAt(index);
  final module = _moduleById(removedModuleId);
  final cpu = (module?['cpu'] as int?) ?? 0;
  final power = (module?['power'] as int?) ?? 0;
  fitting['usedCpu'] = ((fitting['usedCpu'] as int?) ?? 0) - cpu;
  fitting['usedPower'] = ((fitting['usedPower'] as int?) ?? 0) - power;
  if ((fitting['usedCpu'] as int) < 0) fitting['usedCpu'] = 0;
  if ((fitting['usedPower'] as int) < 0) fitting['usedPower'] = 0;
  ship['fitting'] = fitting;
  unawaited(_savePlayersToDisk());

  _send(session.channel, {
    'type': 'fitting',
    'action': 'remove',
    'ok': true,
    'ship': ship,
  });
}

PlayerProfile? _requireAuthenticatedPlayer(
  PlayerSession session, {
  required String actionType,
}) {
  if (!session.authenticated || session.email == null) {
    _send(session.channel, {
      'type': actionType,
      'action': 'error',
      'ok': false,
      'reason': 'not_authenticated',
    });
    return null;
  }
  final profile = players[session.email!];
  if (profile == null) {
    _send(session.channel, {
      'type': actionType,
      'action': 'error',
      'ok': false,
      'reason': 'player_not_found',
    });
    return null;
  }
  return profile;
}

Map<String, dynamic>? _findOwnedShip(PlayerProfile profile, String shipId) {
  for (final ship in profile.hangarShips) {
    if ((ship['id'] as String?) == shipId) {
      return ship;
    }
  }
  return null;
}

Map<String, int> _hullStatsFor(String hull) {
  return hullFittingStats[hull] ??
      const {
        'highSlots': 0,
        'midSlots': 0,
        'lowSlots': 0,
        'cpu': 0,
        'power': 0,
      };
}

Map<String, dynamic>? _moduleById(String moduleId) {
  for (final module in moduleCatalog) {
    if ((module['id'] as String).toLowerCase() == moduleId) {
      return module;
    }
  }
  return null;
}

Map<String, dynamic> _defaultFittingForHull(String hull) {
  final stats = _hullStatsFor(hull);
  return {
    'high': <String>[],
    'mid': <String>[],
    'low': <String>[],
    'usedCpu': 0,
    'usedPower': 0,
    'maxCpu': stats['cpu'] ?? 0,
    'maxPower': stats['power'] ?? 0,
  };
}

Map<String, dynamic> _normalizeFitting(
  Map<String, dynamic> fitting,
  String hull,
) {
  final defaults = _defaultFittingForHull(hull);
  final high = (fitting['high'] as List? ?? const [])
      .whereType<String>()
      .toList(growable: true);
  final mid = (fitting['mid'] as List? ?? const []).whereType<String>().toList(
    growable: true,
  );
  final low = (fitting['low'] as List? ?? const []).whereType<String>().toList(
    growable: true,
  );
  var usedCpu = 0;
  var usedPower = 0;
  for (final id in [...high, ...mid, ...low]) {
    final module = _moduleById(id);
    usedCpu += (module?['cpu'] as int?) ?? 0;
    usedPower += (module?['power'] as int?) ?? 0;
  }

  return {
    ...defaults,
    'high': high,
    'mid': mid,
    'low': low,
    'usedCpu': usedCpu,
    'usedPower': usedPower,
  };
}

Map<String, dynamic> _normalizeShipInstance(Map<String, dynamic> ship) {
  final hull = (ship['hull'] as String? ?? '').toLowerCase();
  final fittingRaw = Map<String, dynamic>.from(
    ship['fitting'] as Map? ?? const {},
  );
  return {...ship, 'fitting': _normalizeFitting(fittingRaw, hull)};
}

void _handleMasteryUnlock(PlayerSession session, Map<String, dynamic> data) {
  if (!session.authenticated || session.email == null) {
    _send(session.channel, {
      'type': 'mastery',
      'action': 'unlock',
      'ok': false,
      'reason': 'not_authenticated',
    });
    return;
  }

  final profile = players[session.email!];
  if (profile == null) {
    _send(session.channel, {
      'type': 'mastery',
      'action': 'unlock',
      'ok': false,
      'reason': 'player_not_found',
    });
    return;
  }

  final hull = (data['hull'] as String? ?? '').trim().toLowerCase();
  final cost = masteryXpCosts[hull];
  if (hull.isEmpty || cost == null) {
    _send(session.channel, {
      'type': 'mastery',
      'action': 'unlock',
      'ok': false,
      'reason': 'invalid_hull',
    });
    return;
  }

  if (profile.masteredHulls.contains(hull)) {
    _send(session.channel, {
      'type': 'mastery',
      'action': 'unlock',
      'ok': true,
      'hull': hull,
      'freeXp': profile.freeXp,
      'alreadyMastered': true,
    });
    return;
  }

  if (profile.freeXp < cost) {
    _send(session.channel, {
      'type': 'mastery',
      'action': 'unlock',
      'ok': false,
      'reason': 'not_enough_free_xp',
      'required': cost,
      'freeXp': profile.freeXp,
    });
    return;
  }

  profile.freeXp -= cost;
  profile.masteredHulls.add(hull);
  unawaited(_savePlayersToDisk());
  _logInfo('mastery_unlocked', {
    'email': session.email,
    'hull': hull,
    'spentXp': cost,
    'freeXp': profile.freeXp,
  });
  _send(session.channel, {
    'type': 'mastery',
    'action': 'unlock',
    'ok': true,
    'hull': hull,
    'spentXp': cost,
    'freeXp': profile.freeXp,
    'alreadyMastered': false,
  });
}

void _handleAuthMessage(
  PlayerSession session,
  String type,
  Map<String, dynamic> data,
) {
  final email = (data['email'] as String? ?? '').trim().toLowerCase();
  final password = data['password'] as String? ?? '';
  if (email.isEmpty || password.isEmpty) {
    _logWarn('auth_rejected_empty_fields', {
      'sid': _sid(session),
      'action': type,
    });
    _send(session.channel, {
      'type': 'auth',
      'action': type,
      'ok': false,
      'reason': 'email_or_password_empty',
    });
    return;
  }

  if (type == 'register') {
    if (players.containsKey(email)) {
      _logWarn('register_failed_exists', {
        'sid': _sid(session),
        'email': email,
      });
      _send(session.channel, {
        'type': 'auth',
        'action': 'register',
        'ok': false,
        'reason': 'already_exists',
      });
      return;
    }
    players[email] = PlayerProfile(
      password: password,
      balance: newPlayerStartingBalance,
      freeXp: newPlayerStartingFreeXp,
      hangarShips: [],
      masteredHulls: [],
    );
    unawaited(_savePlayersToDisk());
    session
      ..authenticated = true
      ..email = email;
    _logInfo('register_success', {'sid': _sid(session), 'email': email});
    _send(session.channel, {'type': 'auth', 'action': 'register', 'ok': true});
    return;
  }

  final profile = players[email];
  final ok = profile != null && profile.password == password;
  if (ok) {
    session
      ..authenticated = true
      ..email = email;
    _logInfo('login_success', {'sid': _sid(session), 'email': email});
  } else {
    _logWarn('login_failed', {'sid': _sid(session), 'email': email});
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
    _logWarn('queue_join_denied_not_authenticated', {'sid': _sid(session)});
    _send(session.channel, {
      'type': 'queue',
      'action': 'join',
      'ok': false,
      'reason': 'not_authenticated',
    });
    return;
  }
  if (session.email == null) {
    _send(session.channel, {
      'type': 'queue',
      'action': 'join',
      'ok': false,
      'reason': 'not_authenticated',
    });
    return;
  }
  final profile = players[session.email!];
  if (profile == null) {
    _send(session.channel, {
      'type': 'queue',
      'action': 'join',
      'ok': false,
      'reason': 'player_not_found',
    });
    return;
  }
  if (session.matchId != null) {
    _logWarn('queue_join_denied_in_match', {
      'sid': _sid(session),
      'matchId': session.matchId,
    });
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
    _logWarn('queue_join_denied_invalid_mode', {
      'sid': _sid(session),
      'mode': mode,
    });
    _send(session.channel, {
      'type': 'queue',
      'action': 'join',
      'ok': false,
      'reason': 'invalid_mode',
    });
    return;
  }

  final shipId = (data['shipId'] as String? ?? '').trim();
  if (shipId.isEmpty) {
    _send(session.channel, {
      'type': 'queue',
      'action': 'join',
      'ok': false,
      'reason': 'ship_not_selected',
    });
    return;
  }
  final selectedShip = _findOwnedShip(profile, shipId);
  if (selectedShip == null) {
    _send(session.channel, {
      'type': 'queue',
      'action': 'join',
      'ok': false,
      'reason': 'ship_not_found',
    });
    return;
  }
  final pointsRaw = selectedShip['points'];
  final points = _parsePoints(pointsRaw);

  _removeFromQueues(session);
  session
    ..queueMode = mode
    ..shipPoints = points
    ..selectedShipId = shipId;
  _queueForMode(mode).add(session);

  _send(session.channel, {
    'type': 'queue',
    'action': 'join',
    'ok': true,
    'mode': mode,
    'shipId': shipId,
    'shipPoints': points,
  });
  _logInfo('queue_join', {
    'sid': _sid(session),
    'email': session.email,
    'mode': mode,
    'shipId': shipId,
    'shipPoints': points,
  });
  _broadcastQueueStatus();
}

void _handleQueueLeave(PlayerSession session) {
  _removeFromQueues(session);
  _logInfo('queue_leave', {'sid': _sid(session), 'email': session.email});
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
    _logWarn('command_ignored_outside_match', {
      'sid': _sid(session),
      'type': type,
      'matchId': session.matchId,
    });
    return;
  }

  final shipId = session.shipId!;
  if (type == 'move') {
    final x = (data['x'] as num?)?.toDouble();
    final y = (data['y'] as num?)?.toDouble();
    if (x == null || y == null) {
      _logWarn('move_command_invalid_payload', {'sid': _sid(session)});
      return;
    }
    commandQueue.add(MoveCommand(shipId, x, y));
    return;
  }

  final targetId = data['targetId'] as int?;
  final radius = (data['radius'] as num?)?.toDouble();
  if (targetId == null || radius == null) {
    _logWarn('orbit_command_invalid_payload', {'sid': _sid(session)});
    return;
  }
  commandQueue.add(OrbitCommand(shipId, targetId, radius));
}

void _handleModuleSetCommand(PlayerSession session, Map<String, dynamic> data) {
  if (session.matchId == null ||
      activeMatch == null ||
      activeMatch!.id != session.matchId ||
      session.shipId == null) {
    _send(session.channel, {
      'type': 'module',
      'action': 'set',
      'ok': false,
      'reason': 'outside_match',
    });
    return;
  }

  final requestedShipId = (data['shipId'] as num?)?.toInt();
  final shipId = session.shipId!;
  if (requestedShipId == null || requestedShipId != shipId) {
    _send(session.channel, {
      'type': 'module',
      'action': 'set',
      'ok': false,
      'reason': 'ship_mismatch',
    });
    return;
  }

  final moduleId = (data['moduleId'] as String? ?? '').trim().toLowerCase();
  final moduleRef = (data['moduleRef'] as String? ?? '').trim().toLowerCase();
  final active = data['active'] == true;
  final targetId = (data['targetId'] as num?)?.toInt();
  final runtime = shipRuntimeById[shipId];
  final moduleState = runtime?.findModule(
    moduleRef: moduleRef.isEmpty ? null : moduleRef,
    moduleId: moduleId.isEmpty ? null : moduleId,
  );
  if (runtime == null || moduleState == null) {
    _send(session.channel, {
      'type': 'module',
      'action': 'set',
      'ok': false,
      'reason': 'module_not_fitted',
      'moduleId': moduleId,
      if (moduleRef.isNotEmpty) 'moduleRef': moduleRef,
    });
    return;
  }

  final effectiveModuleId = moduleState.moduleId;
  if (active) {
    if (_isTargetedModule(effectiveModuleId)) {
      if (targetId == null || world.ships[targetId] == null) {
        _send(session.channel, {
          'type': 'module',
          'action': 'set',
          'ok': false,
          'reason': 'target_not_found',
          'moduleId': effectiveModuleId,
        });
        return;
      }
      if (shipTeamById[targetId] == shipTeamById[shipId]) {
        _send(session.channel, {
          'type': 'module',
          'action': 'set',
          'ok': false,
          'reason': 'target_is_ally',
          'moduleId': effectiveModuleId,
          'targetId': targetId,
        });
        return;
      }
      moduleState.targetId = targetId;
    } else {
      moduleState.targetId = null;
    }
  } else {
    moduleState.targetId = null;
  }
  moduleState.active = active;
  _send(session.channel, {
    'type': 'module',
    'action': 'set',
    'ok': true,
    'shipId': shipId,
    'moduleId': effectiveModuleId,
    'moduleRef': moduleState.moduleRef,
    'active': active,
    if (moduleState.targetId != null) 'targetId': moduleState.targetId,
  });
}

void _processCommands() {
  for (final cmd in commandQueue) {
    final ship = world.ships[cmd.shipId];
    if (ship == null) continue;

    if (cmd is MoveCommand) {
      final target = Vector2(cmd.x, cmd.y);
      final delta = target - ship.position;
      if (delta.length2 <= minDistanceEpsilon) {
        ship.velocity.setZero();
        continue;
      }
      final speedMultiplier = shipRuntimeById[cmd.shipId]?.speedMultiplier ?? 1.0;
      ship.velocity = delta.normalized() * (baseMoveSpeed * speedMultiplier);
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
    _logInfo('matchmaking_attempt', {'mode': mode, 'waiting': queue.length});

    final teams = _buildTeams(queue);
    if (teams == null) {
      _logInfo('matchmaking_skipped_no_balanced_teams', {
        'mode': mode,
        'waiting': queue.length,
      });
      continue;
    }

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
  shipRuntimeById.clear();

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
  _logInfo('match_started', {
    'matchId': id,
    'mode': mode,
    'teamSizeA': teamA.length,
    'teamSizeB': teamB.length,
    'pointsA': pointsA,
    'pointsB': pointsB,
  });
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
  shipRuntimeById[shipId] = _buildShipRuntime(session);
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

ShipRuntimeState _buildShipRuntime(PlayerSession session) {
  final email = session.email;
  final selectedShipId = session.selectedShipId;
  if (email == null || selectedShipId == null) {
    return ShipRuntimeState.withFitting(const <String, dynamic>{});
  }
  final profile = players[email];
  if (profile == null) {
    return ShipRuntimeState.withFitting(const <String, dynamic>{});
  }
  final ship = _findOwnedShip(profile, selectedShipId);
  if (ship == null) {
    return ShipRuntimeState.withFitting(const <String, dynamic>{});
  }

  final hull = (ship['hull'] as String? ?? '').toLowerCase();
  final fitting = _normalizeFitting(
    Map<String, dynamic>.from(ship['fitting'] as Map? ?? const {}),
    hull,
  );
  return ShipRuntimeState.withFitting(fitting);
}

bool _isTargetedModule(String moduleId) {
  return moduleId == 'light_blaster_i' ||
      moduleId == 'small_railgun_i' ||
      moduleId == 'stasis_web_i';
}

void _updateCombat(double dt) {
  if (shipRuntimeById.isEmpty) return;

  for (final runtime in shipRuntimeById.values) {
    runtime.speedMultiplier = 1.0;
  }

  for (final entry in shipRuntimeById.entries) {
    final runtime = entry.value;
    final afterburners = runtime.modules.where(
      (m) => m.moduleId == 'afterburner_i' && m.active,
    );
    for (final ab in afterburners) {
      final needCap = afterburnerCapUsePerSecond * dt;
      if (runtime.capacitor < needCap) {
        ab
          ..active = false
          ..targetId = null;
        continue;
      }
      runtime.capacitor -= needCap;
      runtime.speedMultiplier = math.max(
        runtime.speedMultiplier,
        afterburnerSpeedFactor,
      );
    }
  }

  for (final entry in shipRuntimeById.entries) {
    final sourceShipId = entry.key;
    final sourcePos = world.ships[sourceShipId]?.position;
    if (sourcePos == null) continue;
    final webs = entry.value.modules.where(
      (m) => m.moduleId == 'stasis_web_i' && m.active && m.targetId != null,
    );
    for (final web in webs) {
      final targetId = web.targetId!;
      final targetShip = world.ships[targetId];
      final targetRuntime = shipRuntimeById[targetId];
      if (targetShip == null || targetRuntime == null) {
        web
          ..active = false
          ..targetId = null;
        continue;
      }
      final distance = (targetShip.position - sourcePos).length;
      if (distance > webRange) continue;
      targetRuntime.speedMultiplier *= webSpeedFactor;
    }
  }

  final damageByTarget = <int, double>{};
  for (final entry in shipRuntimeById.entries) {
    final sourceShipId = entry.key;
    final sourcePos = world.ships[sourceShipId]?.position;
    if (sourcePos == null) continue;

    void addWeaponDamage(String moduleId, double range, double dps) {
      final weapons = entry.value.modules.where(
        (m) => m.moduleId == moduleId && m.active && m.targetId != null,
      );
      for (final module in weapons) {
        final targetId = module.targetId!;
        final targetShip = world.ships[targetId];
        if (targetShip == null || shipRuntimeById[targetId] == null) {
          module
            ..active = false
            ..targetId = null;
          continue;
        }
        if (shipTeamById[targetId] == shipTeamById[sourceShipId]) {
          module
            ..active = false
            ..targetId = null;
          continue;
        }
        final distance = (targetShip.position - sourcePos).length;
        if (distance > range) continue;
        damageByTarget[targetId] = (damageByTarget[targetId] ?? 0) + dps * dt;
      }
    }

    addWeaponDamage('light_blaster_i', blasterRange, blasterDps);
    addWeaponDamage('small_railgun_i', railgunRange, railgunDps);
  }

  final destroyed = <int>[];
  for (final entry in damageByTarget.entries) {
    final targetRuntime = shipRuntimeById[entry.key];
    if (targetRuntime == null) continue;
    var damage = entry.value;
    if (damage <= 0) continue;
    if (targetRuntime.shield > 0) {
      final applied = math.min(targetRuntime.shield, damage);
      targetRuntime.shield -= applied;
      damage -= applied;
    }
    if (damage > 0 && targetRuntime.armor > 0) {
      final applied = math.min(targetRuntime.armor, damage);
      targetRuntime.armor -= applied;
      damage -= applied;
    }
    if (targetRuntime.armor <= 0) {
      destroyed.add(entry.key);
    }
  }

  for (final shipId in destroyed) {
    _destroyShip(shipId);
  }
}

void _destroyShip(int shipId) {
  world.ships.remove(shipId);
  shipOwnerById.remove(shipId);
  shipTeamById.remove(shipId);
  shipPointsById.remove(shipId);
  shipRuntimeById.remove(shipId);
  for (final runtime in shipRuntimeById.values) {
    for (final module in runtime.modules) {
      if (module.targetId == shipId) {
        module
          ..active = false
          ..targetId = null;
      }
    }
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
  shipRuntimeById.clear();
  activeMatch = null;
  _logInfo('match_ended', {
    'matchId': match.id,
    'winner': winner,
    'reason': reason,
    'scoreA': scoreA,
    'scoreB': scoreB,
  });
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
          'runtime': shipRuntimeById[s.id]?.toJson(),
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
  _logInfo('client_disconnected', {
    'sid': _sid(session),
    'email': session.email,
    'matchId': session.matchId,
  });
  sessionsByChannel.remove(session.channel);
  _removeFromQueues(session);

  if (session.shipId != null) {
    _destroyShip(session.shipId!);
  }

  if (activeMatch != null && session.matchId == activeMatch!.id) {
    _updateMatchLifecycle();
  }

  _broadcastQueueStatus();
}

void _removeFromQueues(PlayerSession session) {
  final removedRandom = waitingRandom.remove(session);
  final removedTournament = waitingTournament.remove(session);
  if (removedRandom || removedTournament) {
    _logInfo('queue_removed', {
      'sid': _sid(session),
      'fromRandom': removedRandom,
      'fromTournament': removedTournament,
    });
  }
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

String _sid(PlayerSession session) => session.channel.hashCode.toString();

void _logInfo(String event, [Map<String, Object?> data = const {}]) {
  _log('INFO', event, data);
}

void _logWarn(String event, [Map<String, Object?> data = const {}]) {
  _log('WARN', event, data);
}

void _log(String level, String event, Map<String, Object?> data) {
  final ts = DateTime.now().toIso8601String();
  final suffix = data.isEmpty ? '' : ' ${jsonEncode(data)}';
  print('[$ts][$level] $event$suffix');
}

class PlayerSession {
  final WebSocketChannel channel;
  bool authenticated = false;
  String? email;
  String? queueMode;
  String? selectedShipId;
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

class ShipRuntimeState {
  double shield;
  double armor;
  double capacitor;
  double speedMultiplier;
  final List<ModuleRuntimeState> modules;

  ShipRuntimeState({
    required this.shield,
    required this.armor,
    required this.capacitor,
    required this.modules,
    this.speedMultiplier = 1.0,
  });

  factory ShipRuntimeState.withFitting(Map<String, dynamic> fitting) {
    final modules = <ModuleRuntimeState>[];
    void addSlot(String slotName) {
      final list = (fitting[slotName] as List? ?? const []).whereType<String>();
      var index = 0;
      for (final rawModuleId in list) {
        final moduleId = rawModuleId.toLowerCase();
        if (_moduleById(moduleId) == null) continue;
        modules.add(
          ModuleRuntimeState(
            moduleId: moduleId,
            moduleRef: '$slotName:$index',
            slot: slotName,
          ),
        );
        index++;
      }
    }

    addSlot('high');
    addSlot('mid');
    addSlot('low');
    return ShipRuntimeState(
      shield: atronShieldHp,
      armor: atronArmorHp,
      capacitor: atronCapacitor,
      modules: modules,
    );
  }

  Map<String, dynamic> toJson() => {
    'shield': shield,
    'armor': armor,
    'capacitor': capacitor,
    'speedMultiplier': speedMultiplier,
    'modules': modules.map((m) => m.toJson()).toList(growable: false),
  };

  ModuleRuntimeState? findModule({String? moduleRef, String? moduleId}) {
    if (moduleRef != null && moduleRef.isNotEmpty) {
      for (final module in modules) {
        if (module.moduleRef == moduleRef) return module;
      }
    }
    if (moduleId != null && moduleId.isNotEmpty) {
      for (final module in modules) {
        if (module.moduleId == moduleId) return module;
      }
    }
    return null;
  }
}

class ModuleRuntimeState {
  final String moduleId;
  final String moduleRef;
  final String slot;
  bool active;
  int? targetId;

  ModuleRuntimeState({
    required this.moduleId,
    required this.moduleRef,
    required this.slot,
    this.active = false,
    this.targetId,
  });

  Map<String, dynamic> toJson() => {
    'moduleId': moduleId,
    'moduleRef': moduleRef,
    'slot': slot,
    'active': active,
    if (targetId != null) 'targetId': targetId,
  };
}

class PlayerProfile {
  final String password;
  int balance;
  int freeXp;
  List<Map<String, dynamic>> hangarShips;
  List<String> masteredHulls;

  PlayerProfile({
    required this.password,
    required this.balance,
    required this.freeXp,
    required this.hangarShips,
    required this.masteredHulls,
  });

  Map<String, dynamic> toJson() => {
    'password': password,
    'balance': balance,
    'freeXp': freeXp,
    'hangarShips': hangarShips,
    'masteredHulls': masteredHulls,
  };

  factory PlayerProfile.fromJson(Map<String, dynamic> json) {
    final shipsRaw = (json['hangarShips'] as List? ?? const []);
    final ships = shipsRaw
        .whereType<Map>()
        .map((e) => _normalizeShipInstance(Map<String, dynamic>.from(e)))
        .toList(growable: true);
    final masteredHullsRaw = (json['masteredHulls'] as List? ?? const []);
    final masteredHulls = masteredHullsRaw
        .whereType<String>()
        .map((e) => e.toLowerCase())
        .toList(growable: true);

    return PlayerProfile(
      password: json['password'] as String? ?? '',
      balance: (json['balance'] as num?)?.toInt() ?? newPlayerStartingBalance,
      freeXp: (json['freeXp'] as num?)?.toInt() ?? newPlayerStartingFreeXp,
      hangarShips: ships,
      masteredHulls: masteredHulls,
    );
  }
}

Future<void> _loadPlayersFromDisk() async {
  final file = File(playersStoragePath);
  if (!await file.exists()) {
    _logInfo('players_storage_missing', {'path': playersStoragePath});
    return;
  }

  try {
    final content = await file.readAsString();
    if (content.trim().isEmpty) {
      _logWarn('players_storage_empty', {'path': playersStoragePath});
      return;
    }
    final decoded = jsonDecode(content);
    if (decoded is! Map) {
      _logWarn('players_storage_invalid_root', {'path': playersStoragePath});
      return;
    }

    final root = Map<String, dynamic>.from(decoded);
    final rawPlayers = root['players'];
    if (rawPlayers is! Map) {
      _logWarn('players_storage_invalid_players', {'path': playersStoragePath});
      return;
    }

    players.clear();
    for (final entry in rawPlayers.entries) {
      final email = entry.key.toString().trim().toLowerCase();
      final value = entry.value;
      if (email.isEmpty || value is! Map) continue;
      players[email] = PlayerProfile.fromJson(Map<String, dynamic>.from(value));
    }

    _logInfo('players_loaded', {
      'path': playersStoragePath,
      'count': players.length,
    });
  } catch (e) {
    _logWarn('players_load_failed', {
      'path': playersStoragePath,
      'error': '$e',
    });
  }
}

Future<void> _savePlayersToDisk() async {
  try {
    final file = File(playersStoragePath);
    await file.parent.create(recursive: true);
    final payload = {
      'players': players.map(
        (email, profile) => MapEntry(email, profile.toJson()),
      ),
      'savedAt': DateTime.now().toIso8601String(),
    };
    await file.writeAsString(jsonEncode(payload));
    _logInfo('players_saved', {
      'path': playersStoragePath,
      'count': players.length,
    });
  } catch (e) {
    _logWarn('players_save_failed', {
      'path': playersStoragePath,
      'error': '$e',
    });
  }
}
