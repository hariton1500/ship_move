import 'dart:math' as math;
import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flame/experimental.dart';
import 'package:flame/input.dart';
import 'package:flutter/material.dart';
import 'package:ship_move/shipcomponent.dart';

// Основной игровой класс: камера, ввод и логика сцены.
class SpaceGame extends FlameGame with DoubleTapDetector, ScrollDetector, PanDetector {
  late ShipComponent player, point;
  late TextComponent _zoomHud; // отладочный HUD
  bool _shipsReady = false; // защита от доступа до onLoad
  ShipComponent? lastTappedShip; // последний кликнутый чужой корабль
  late RectangleComponent _infoPanel; // нижняя информационная панель
  late TextComponent _infoText; // текст внутри панели
  late ButtonComponent _moveToButton; // кнопка "двигаться к"
  late TextComponent _moveToLabel; // подпись кнопки
  late ButtonComponent _orbitButton; // кнопка "держать орбиту"
  late TextComponent _orbitLabel; // подпись кнопки
  final List<ButtonComponent> _radiusButtons = []; // кнопки радиуса
  final List<TextComponent> _radiusLabels = []; // подписи радиуса
  late ButtonComponent _customRadiusButton; // кнопка произвольного радиуса
  late TextComponent _customRadiusLabel; // подпись произвольного радиуса
  bool _uiReady = false; // UI готова после onLoad
  String _actionNote = ''; // диагностическая строка для действий
  bool _orbitActive = false; // включен режим орбиты
  ShipComponent? _orbitTarget; // цель орбиты
  double _orbitRadius = 20000; // радиус орбиты по умолчанию
  double _orbitAngle = 0.0; // текущий угол орбиты
  final double _orbitAngularSpeed = 0.2; // рад/сек
  static const double worldSizeMeters = 100000; // размер мира
  double _targetZoom = 1.0; // целевой зум
  final double _minZoom = 0.1; // ограничения зума
  final double _maxZoom = 1;
  final double _zoomResponse = 10.0; // больше = резче
  final double _fitPadding = 200.0; // поля вокруг кораблей при автоподгонке

  @override
  Future<void> onLoad() async {
    // Ограничиваем камеру рамками мира.
    camera.setBounds(
      Rectangle.fromLTWH(0, 0, worldSizeMeters, worldSizeMeters),
      considerViewport: true,
    );

    // Создаем игрока.
    player = ShipComponent(index: 0, isPlayer: true)
      ..position = Vector2(50000, 50000);

    world.add(player);

    // Настраиваем камеру.
    camera.viewfinder.anchor = Anchor.center;
    camera.viewfinder.zoom = _targetZoom;

    // Вторая точка/корабль для теста.
    point = ShipComponent(index: 1, onTap: _onShipTapped)
      ..position = Vector2(60000, 60000);
    world.add(point);

    _shipsReady = true;
    _fitToShips();

    // HUD с диагностикой.
    _zoomHud = TextComponent(
      text: 'zoom: ${camera.viewfinder.zoom.toStringAsFixed(2)}',
      position: Vector2(8, 8),
      anchor: Anchor.topLeft,
      textRenderer: TextPaint(
        style: const TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 14,
        ),
      ),
    );
    camera.viewport.add(_zoomHud);

    _infoPanel = RectangleComponent(
      paint: Paint()..color = const Color(0xFF20232A),
    );
    _infoText = TextComponent(
      text: 'selected ship: none',
      position: Vector2(12, 8),
      anchor: Anchor.topLeft,
      textRenderer: TextPaint(
        style: const TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 14,
        ),
      ),
    );
    _infoPanel.add(_infoText);
    _moveToButton = ButtonComponent(
      button: RectangleComponent(
        size: Vector2(120, 32),
        paint: Paint()..color = const Color(0xFF3A3F4B),
      ),
      buttonDown: RectangleComponent(
        size: Vector2(120, 32),
        paint: Paint()..color = const Color(0xFF2C3038),
      ),
      onPressed: _onMoveToPressed,
    );
    _moveToLabel = TextComponent(
      text: '->',
      anchor: Anchor.center,
      textRenderer: TextPaint(
        style: const TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    _moveToButton.button!.add(_moveToLabel);
    _infoPanel.add(_moveToButton);

    _orbitButton = ButtonComponent(
      button: RectangleComponent(
        size: Vector2(140, 32),
        paint: Paint()..color = const Color(0xFF3A3F4B),
      ),
      buttonDown: RectangleComponent(
        size: Vector2(140, 32),
        paint: Paint()..color = const Color(0xFF2C3038),
      ),
      onPressed: _onOrbitPressed,
    );
    _orbitLabel = TextComponent(
      text: 'orbit',
      anchor: Anchor.center,
      textRenderer: TextPaint(
        style: const TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    _orbitButton.button!.add(_orbitLabel);
    _infoPanel.add(_orbitButton);

    // Кнопки фиксированных радиусов.
    _addRadiusButton('500', 500);
    _addRadiusButton('1k', 1000);
    _addRadiusButton('5k', 5000);
    _addRadiusButton('10k', 10000);
    _addRadiusButton('20k', 20000);
    _customRadiusButton = _makePanelButton(
      label: 'custom',
      onPressed: _openRadiusInput,
      width: 70,
    );
    _customRadiusLabel = _customRadiusButton.button!.children.whereType<TextComponent>().first;
    _infoPanel.add(_customRadiusButton);

    camera.viewport.add(_infoPanel);
    _layoutInfoPanel();
    _uiReady = true;
  }

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    if (_uiReady) {
      _layoutInfoPanel();
    }
    // При изменении размера экрана пересчитываем камеру.
    if (!_shipsReady) return;
    _fitToShips();
  }

  void _layoutInfoPanel() {
    if (!_uiReady) return;
    final viewportSize = camera.viewport.virtualSize;
    if (viewportSize.x == 0 || viewportSize.y == 0) {
      return;
    }
    final panelHeight = viewportSize.y * 0.2;
    _infoPanel
      ..size = Vector2(viewportSize.x, panelHeight)
      ..position = Vector2(0, viewportSize.y - panelHeight)
      ..anchor = Anchor.topLeft;
    _infoText.position = Vector2(12, 8);
    final buttonSize = _moveToButton.size;
    _moveToButton.position = Vector2(
      _infoPanel.size.x - buttonSize.x - 12,
      8,
    );
    _moveToLabel.position = buttonSize / 2;
    final orbitSize = _orbitButton.size;
    _orbitButton.position = Vector2(
      _moveToButton.position.x - orbitSize.x - 12,
      8,
    );
    _orbitLabel.position = orbitSize / 2;
    _layoutRadiusButtons(panelHeight);
  }

  void _layoutRadiusButtons(double panelHeight) {
    if (_radiusButtons.isEmpty) return;
    const gap = 8.0;
    final rowY = panelHeight - _radiusButtons.first.size.y - 8;
    var x = 12.0;
    for (var i = 0; i < _radiusButtons.length; i++) {
      final b = _radiusButtons[i];
      final label = _radiusLabels[i];
      b.position = Vector2(x, rowY);
      label.position = b.size / 2;
      x += b.size.x + gap;
    }
    _customRadiusButton.position = Vector2(x, rowY);
    _customRadiusLabel.position = _customRadiusButton.size / 2;
  }

  void _fitToShips() {
    // Подгоняем камеру так, чтобы все корабли были видны.
    if (!_shipsReady) {
      return;
    }
    final viewportSize = camera.viewport.virtualSize;
    if (viewportSize.x == 0 || viewportSize.y == 0) {
      return;
    }
    camera.stop();

    final ships = [player, point];
    // Находим границы всех кораблей.
    double minX = ships.first.position.x;
    double maxX = ships.first.position.x;
    double minY = ships.first.position.y;
    double maxY = ships.first.position.y;

    for (final s in ships) {
      minX = math.min(minX, s.position.x);
      maxX = math.max(maxX, s.position.x);
      minY = math.min(minY, s.position.y);
      maxY = math.max(maxY, s.position.y);
    }

    final width = (maxX - minX) + _fitPadding * 2;
    final height = (maxY - minY) + _fitPadding * 2;
    final center = Vector2((minX + maxX) * 0.5, (minY + maxY) * 0.5);

    // Выбираем зум по меньшей из осей.
    final zoomX = viewportSize.x / width;
    final zoomY = viewportSize.y / height;
    _targetZoom = math.min(zoomX, zoomY).clamp(_minZoom, _maxZoom);
    camera.viewfinder.zoom = _targetZoom;
    camera.viewfinder.position = center;
  }

  @override
  void onScroll(PointerScrollInfo info) {
    // Колесико мыши: меняем целевой зум.
    final delta = info.scrollDelta.global.y;
    final factor = 1 - delta * 0.001;
    _targetZoom = (_targetZoom * factor).clamp(_minZoom, _maxZoom);
  }

  // Хук на клик по чужому кораблю (пока без логики).
  void _onShipTapped(ShipComponent ship) {
    lastTappedShip = ship;
  }

  void _onMoveToPressed() {
    if (lastTappedShip == null) {
      _actionNote = 'action: move to (no target)';
      return;
    }
    final target = lastTappedShip!.position.clone();
    player.moveTo(target);
    _actionNote = 'action: move to ship ${lastTappedShip!.index}';
  }

  void _onOrbitPressed() {
    if (lastTappedShip == null) {
      _actionNote = 'action: orbit (no target)';
      return;
    }
    _orbitTarget = lastTappedShip;
    _orbitActive = true;
    final toPlayer = player.position - _orbitTarget!.position;
    _orbitAngle = math.atan2(toPlayer.y, toPlayer.x);
    _actionNote =
        'action: orbit ship ${_orbitTarget!.index} r=${_orbitRadius.toStringAsFixed(0)}';
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (!_shipsReady) return;
    // Плавно двигаем зум к цели.
    final current = camera.viewfinder.zoom;
    final t = 1 - math.exp(-_zoomResponse * dt);
    camera.viewfinder.zoom = current + (_targetZoom - current) * t;
    if (_orbitActive && _orbitTarget != null) {
      _orbitAngle += _orbitAngularSpeed * dt;
      final offset = Vector2(
        math.cos(_orbitAngle),
        math.sin(_orbitAngle),
      ) * _orbitRadius;
      player.moveTo(_orbitTarget!.position + offset);
    }
    // Диагностика координат.
    final pWorld = player.position;
    final qWorld = point.position;
    final pScreen = camera.localToGlobal(pWorld);
    final qScreen = camera.localToGlobal(qWorld);
    _zoomHud.text = [
      'zoom: ${camera.viewfinder.zoom.toStringAsFixed(2)}',
      'player world: ${pWorld.x.toStringAsFixed(1)}, ${pWorld.y.toStringAsFixed(1)}',
      'player screen: ${pScreen.x.toStringAsFixed(1)}, ${pScreen.y.toStringAsFixed(1)}',
      'point world: ${qWorld.x.toStringAsFixed(1)}, ${qWorld.y.toStringAsFixed(1)}',
      'point screen: ${qScreen.x.toStringAsFixed(1)}, ${qScreen.y.toStringAsFixed(1)}',
    ].join('\n');
    _infoText.text = lastTappedShip == null
        ? 'selected ship: none'
        : 'selected ship index: ${lastTappedShip!.index}';
    if (_actionNote.isNotEmpty) {
      _infoText.text += '\n$_actionNote';
    }
  }

  void setOrbitRadius(double radius) {
    if (radius <= 0) return;
    _orbitRadius = radius;
    _actionNote = 'orbit radius: ${_orbitRadius.toStringAsFixed(0)}';
  }

  void _addRadiusButton(String label, double radius) {
    final button = _makePanelButton(
      label: label,
      onPressed: () => setOrbitRadius(radius),
      width: 52,
    );
    _radiusButtons.add(button);
    _radiusLabels.add(
      button.button!.children.whereType<TextComponent>().first,
    );
    _infoPanel.add(button);
  }

  ButtonComponent _makePanelButton({
    required String label,
    required VoidCallback onPressed,
    double width = 64,
  }) {
    final text = TextComponent(
      text: label,
      anchor: Anchor.center,
      textRenderer: TextPaint(
        style: const TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    final button = ButtonComponent(
      button: RectangleComponent(
        size: Vector2(width, 28),
        paint: Paint()..color = const Color(0xFF3A3F4B),
      )..add(text),
      buttonDown: RectangleComponent(
        size: Vector2(width, 28),
        paint: Paint()..color = const Color(0xFF2C3038),
      ),
      onPressed: onPressed,
    );
    return button;
  }

  void _openRadiusInput() {
    overlays.add('radiusInput');
  }

  @override
  void onPanUpdate(DragUpdateInfo info) {
    // Перетаскивание: сдвиг камеры.
    final delta = info.delta.global;
    final zoom = camera.viewfinder.zoom;
    camera.viewfinder.position -= delta / zoom;
  }

  @override
  void onDoubleTapDown(TapDownInfo info) {
    // Двойной тап: задать цель игроку.
    final worldPos = camera.globalToLocal(info.eventPosition.widget);
    player.moveTo(worldPos);
  }
}
