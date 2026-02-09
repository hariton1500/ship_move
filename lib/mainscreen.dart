import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:ship_move/spacegame.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {

  late SpaceGame game;

  @override
  void initState() {
    super.initState();
    game = SpaceGame();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(onPressed: () {
            game.player.target = Vector2(500, 500);
          }, icon: Icon(Icons.move_to_inbox))
        ],
      ),
      body: Center(
        child: GameWidget(game: game),
      ),
    );
  }
}