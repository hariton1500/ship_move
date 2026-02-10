import 'package:flutter/material.dart';
import 'package:ship_move/mainscreen.dart';

void main() {
  // Точка входа приложения.
  runApp(const MainApp());
}

// Корневой виджет приложения.
class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Базовое приложение с главным экраном.
    return const MaterialApp(
      home: MainScreen(),
    );
  }
}
