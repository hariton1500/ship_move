import 'dart:async';
import 'package:flutter/material.dart';
import 'auth/auth_screen.dart';
import 'mainscreen.dart';
import 'networkclient.dart';
import 'ship_mastery_screen.dart';
import 'ship_fitting_screen.dart';
import 'ship_shop_screen.dart';

class HangarRoomScreen extends StatefulWidget {
  const HangarRoomScreen({super.key, required this.accountEmail});

  final String accountEmail;

  @override
  State<HangarRoomScreen> createState() => _HangarRoomScreenState();
}

class _HangarRoomScreenState extends State<HangarRoomScreen> {
  final NetworkClient _network = NetworkClient.instance;
  StreamSubscription<Map<String, dynamic>>? _eventSub;
  bool _loading = true;
  String _status = 'Loading hangar...';
  String _faction = 'gals';
  int _balance = 0;
  int _freeXp = 0;
  int _atronMasteryXpCost = 5;
  List<Map<String, dynamic>> _ships = const [];
  String? _selectedShipId;
  bool _openingMatch = false;

  @override
  void initState() {
    super.initState();
    _eventSub = _network.events.listen(_onServerEvent);
    _loadHangar();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  Future<void> _loadHangar() async {
    final payload = await _network.fetchHangarRoom();
    if (!mounted) return;
    final ok = payload['ok'] == true;
    if (!ok) {
      setState(() {
        _loading = false;
        _status = 'Hangar load failed: ${payload['reason'] ?? "unknown"}';
      });
      return;
    }
    final ships = (payload['ships'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
    setState(() {
      _loading = false;
      _faction = (payload['faction'] as String?) ?? _faction;
      _balance = (payload['balance'] as num?)?.toInt() ?? 0;
      _freeXp = (payload['freeXp'] as num?)?.toInt() ?? 0;
      final mastery = payload['masteryCosts'];
      if (mastery is Map) {
        _atronMasteryXpCost =
            (mastery['atron'] as num?)?.toInt() ?? _atronMasteryXpCost;
      }
      _ships = ships;
      if (_ships.isEmpty) {
        _selectedShipId = null;
      } else if (_selectedShipId == null ||
          !_ships.any((s) => s['id'] == _selectedShipId)) {
        _selectedShipId = _ships.first['id'] as String?;
      }
      _status = 'Hangar ready';
    });
  }

  void _onServerEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    final type = event['type'] as String?;
    if (type == 'queue_status') {
      final randomWaiting = event['randomWaiting'];
      final tournamentWaiting = event['tournamentWaiting'];
      setState(() {
        _status = 'Queue: random=$randomWaiting tournament=$tournamentWaiting';
      });
    }
    if (type == 'match_started') {
      setState(() {
        _status = 'Match started. Enter battle room.';
      });
      _openBattleFromMatchEvent(event);
    }
  }

  Future<void> _joinQueue(String mode) async {
    Map<String, dynamic>? selected;
    for (final ship in _ships) {
      if (ship['id'] == _selectedShipId) {
        selected = ship;
        break;
      }
    }
    if (selected == null) {
      setState(() {
        _status = 'Select ship in hangar before joining queue';
      });
      return;
    }
    final shipId = (selected['id'] as String?) ?? '';
    final shipPoints = (selected['points'] as num?)?.toInt() ?? 10;
    final result = await _network.joinQueue(
      mode: mode,
      shipId: shipId,
      shipPoints: shipPoints,
    );
    if (!mounted) return;
    setState(() {
      _status = result.ok
          ? 'Joined $mode queue with $shipId'
          : 'Queue join failed: ${result.reason ?? "unknown"}';
    });
  }

  Future<void> _leaveQueue() async {
    final result = await _network.leaveQueue();
    if (!mounted) return;
    setState(() {
      _status = result.ok
          ? 'Left queue'
          : 'Queue leave failed: ${result.reason ?? "unknown"}';
    });
  }

  void _openBattle() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MainScreen(accountEmail: widget.accountEmail),
      ),
    );
  }

  void _openBattleFromMatchEvent(Map<String, dynamic> event) {
    if (_openingMatch) return;
    _openingMatch = true;
    final matchId = (event['matchId'] as num?)?.toInt();
    final shipId = (event['shipId'] as num?)?.toInt();
    final mode = event['mode'] as String?;
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => MainScreen(
              accountEmail: widget.accountEmail,
              matchId: matchId,
              shipId: shipId,
              mode: mode,
            ),
          ),
        )
        .whenComplete(() {
          _openingMatch = false;
        });
  }

  Future<void> _openMastery() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ShipMasteryScreen(accountEmail: widget.accountEmail),
      ),
    );
    if (!mounted) return;
    await _loadHangar();
  }

  Future<void> _openShop() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ShipShopScreen(accountEmail: widget.accountEmail),
      ),
    );
    if (!mounted) return;
    await _loadHangar();
  }

  Future<void> _openFitting() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ShipFittingScreen(accountEmail: widget.accountEmail),
      ),
    );
    if (!mounted) return;
    await _loadHangar();
  }

  void _logout() {
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => const AuthScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Hangar: ${widget.accountEmail}'),
        actions: [
          IconButton(onPressed: _logout, icon: const Icon(Icons.logout)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Faction: $_faction'),
                  const SizedBox(height: 4),
                  Text('Balance: $_balance'),
                  const SizedBox(height: 4),
                  Text('Free XP: $_freeXp'),
                  const SizedBox(height: 4),
                  Text('Atron mastery cost: $_atronMasteryXpCost XP'),
                  const SizedBox(height: 8),
                  Text('Status: $_status'),
                  const SizedBox(height: 16),
                  const Text(
                    'Your Hangar',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: _ships.isEmpty
                        ? const Text('No ships in hangar')
                        : ListView.builder(
                            itemCount: _ships.length,
                            itemBuilder: (context, index) {
                              final ship = _ships[index];
                              return Card(
                                child: ListTile(
                                  selected: ship['id'] == _selectedShipId,
                                  onTap: () {
                                    setState(() {
                                      _selectedShipId = ship['id'] as String?;
                                      _status = 'Selected ship: ${ship['id']}';
                                    });
                                  },
                                  title: Text('${ship['name']}'),
                                  subtitle: Text(
                                    'class=${ship['class']} hull=${ship['hull']} points=${ship['points']}',
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: _openShop,
                          child: const Text('Ship Shop'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          onPressed: _selectedShipId == null
                              ? null
                              : () => _joinQueue('random'),
                          child: const Text('Join Random'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _selectedShipId == null
                              ? null
                              : () => _joinQueue('tournament'),
                          child: const Text('Join Tournament'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _openFitting,
                          child: const Text('Ship Fitting'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _openMastery,
                          child: const Text('Ship Mastery'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _leaveQueue,
                          child: const Text('Leave Queue'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          onPressed: _openBattle,
                          child: const Text('Open Battle Room'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }
}
