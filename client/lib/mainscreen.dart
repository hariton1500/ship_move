import 'dart:async';
import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'auth/auth_screen.dart';
import 'networkclient.dart';
import 'space_game.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({
    super.key,
    required this.accountEmail,
    this.matchId,
    this.shipId,
    this.mode,
  });

  final String accountEmail;
  final int? matchId;
  final int? shipId;
  final String? mode;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  late SpaceGame game;
  final NetworkClient _network = NetworkClient.instance;
  StreamSubscription<Map<String, dynamic>>? _eventSub;
  String _serverStatus = 'Lobby';

  @override
  void initState() {
    super.initState();
    game = SpaceGame(network: _network, playerShipId: widget.shipId);
    _eventSub = _network.events.listen(_onServerEvent);
    if (widget.matchId != null) {
      _serverStatus =
          'In match #${widget.matchId} mode=${widget.mode ?? "unknown"} ship=${widget.shipId ?? "n/a"}';
      game.setBattleContext(
        playerShipId: widget.shipId,
        matchId: widget.matchId,
      );
    }
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  void _onServerEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    if (!mounted || type == null) return;
    switch (type) {
      case 'queue_status':
        final randomWaiting = event['randomWaiting'];
        final tournamentWaiting = event['tournamentWaiting'];
        setState(() {
          _serverStatus =
              'Queue: random=$randomWaiting tournament=$tournamentWaiting';
        });
        break;
      case 'match_started':
        final matchId = (event['matchId'] as num?)?.toInt();
        final shipId = (event['shipId'] as num?)?.toInt();
        final team = event['team'];
        final durationSec = event['durationSec'];
        final mode = event['mode'];
        game.setBattleContext(playerShipId: shipId, matchId: matchId);
        setState(() {
          _serverStatus =
              'Match started: mode=$mode team=$team duration=${durationSec}s';
        });
        break;
      case 'state':
        game.applyServerState(event);
        final remainingSec = event['remainingSec'];
        final shipCount = (event['ships'] as List?)?.length ?? 0;
        setState(() {
          _serverStatus =
              'Battle state: ships=$shipCount remaining=${remainingSec ?? "-"}s';
        });
        break;
      case 'match_ended':
        final winner = event['winner'];
        final reason = event['reason'];
        final scoreA = event['scoreA'];
        final scoreB = event['scoreB'];
        setState(() {
          _serverStatus =
              'Match ended: winner=$winner reason=$reason score A:$scoreA B:$scoreB';
        });
        break;
      default:
        break;
    }
  }

  Future<void> _leaveQueue() async {
    final result = await _network.leaveQueue();
    if (!mounted) return;
    setState(() {
      _serverStatus = result.ok
          ? 'Left queue'
          : 'Queue leave failed: ${result.reason ?? "unknown"}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Pilot: ${widget.accountEmail}'),
        actions: [
          IconButton(
            onPressed: () {
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const AuthScreen()),
              );
            },
            icon: const Icon(Icons.logout),
          ),
          IconButton(
            onPressed: () {
              game.movePlayerTo(Vector2(500, 500));
            },
            icon: const Icon(Icons.move_to_inbox),
          ),
          IconButton(
            onPressed: _leaveQueue,
            icon: const Icon(Icons.clear),
            tooltip: 'Leave Queue',
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: const Color(0x11000000),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(_serverStatus),
          ),
          Expanded(
            child: Center(
              child: GameWidget(
                game: game,
                overlayBuilderMap: {
                  'radiusInput': (context, game) {
                    return RadiusInputOverlay(game: game as SpaceGame);
                  },
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class RadiusInputOverlay extends StatefulWidget {
  const RadiusInputOverlay({super.key, required this.game});

  final SpaceGame game;

  @override
  State<RadiusInputOverlay> createState() => _RadiusInputOverlayState();
}

class _RadiusInputOverlayState extends State<RadiusInputOverlay> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double? _parseRadius(String text) {
    final trimmed = text.trim().toLowerCase();
    if (trimmed.isEmpty) return null;
    if (trimmed.endsWith('k')) {
      final number = double.tryParse(trimmed.substring(0, trimmed.length - 1));
      if (number == null) return null;
      return number * 1000;
    }
    return double.tryParse(trimmed);
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        color: const Color(0xCC20232A),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Радиус орбиты:',
                  style: TextStyle(color: Colors.white),
                ),
              ),
              SizedBox(
                width: 120,
                child: TextField(
                  controller: _controller,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '20000 / 20k',
                    hintStyle: TextStyle(color: Colors.white54),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white54),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () {
                  final radius = _parseRadius(_controller.text);
                  if (radius != null && radius > 0) {
                    widget.game.setOrbitRadius(radius);
                  }
                  widget.game.overlays.remove('radiusInput');
                },
                child: const Text('OK'),
              ),
              TextButton(
                onPressed: () {
                  widget.game.overlays.remove('radiusInput');
                },
                child: const Text('Отмена'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
