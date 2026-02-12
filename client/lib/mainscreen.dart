import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'space_game.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {

  late SpaceGame game; // экземпляр игры

  @override
  void initState() {
    super.initState();
    // Инициализация игры один раз.
    game = SpaceGame();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        actions: [
          // Тестовая кнопка: поставить цель игроку.
          IconButton(onPressed: () {
            game.player.target = Vector2(500, 500);
          }, icon: Icon(Icons.move_to_inbox))
        ],
      ),
      body: Center(
        // Встраиваем игровое поле.
        child: GameWidget(
          game: game,
          overlayBuilderMap: {
            'radiusInput': (context, game) {
              return RadiusInputOverlay(game: game as SpaceGame);
            },
          },
        ),
      ),
    );
  }
}

// Оверлей для ввода произвольного радиуса орбиты.
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
