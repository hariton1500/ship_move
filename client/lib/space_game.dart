import 'dart:math' as math;
import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/experimental.dart';
import 'package:flame/game.dart';
import 'package:flame/input.dart';
import 'package:flutter/material.dart';
import 'package:space_core/battle_rules.dart';
import 'networkclient.dart';
import 'presentation/shipcomponent.dart';

class SpaceGame extends FlameGame
    with DoubleTapDetector, ScrollDetector, PanDetector {
  SpaceGame({required this.network, int? playerShipId})
    : _playerShipId = playerShipId;

  final NetworkClient network;
  int? _playerShipId;

  final Map<int, ShipComponent> _shipsById = {};
  bool _didInitialWorldFit = false;
  ShipComponent? lastTappedShip;

  late TextComponent _zoomHud;
  late TextComponent _battleHud;
  late RectangleComponent _infoPanel;
  late TextComponent _infoText;
  late ButtonComponent _moveToButton;
  late TextComponent _moveToLabel;
  late ButtonComponent _orbitButton;
  late TextComponent _orbitLabel;
  final List<ButtonComponent> _moduleButtons = [];
  final List<TextComponent> _moduleButtonLabels = [];
  final List<ButtonComponent> _radiusButtons = [];
  final List<TextComponent> _radiusLabels = [];
  late ButtonComponent _customRadiusButton;
  late TextComponent _customRadiusLabel;

  bool _uiReady = false;
  String _actionNote = '';
  double _orbitRadius = 20000;
  int? _lastServerMatchId;
  int _lastServerRemainingSec = 0;
  double _playerShield = 0;
  double _playerArmor = 0;
  double _playerCapacitor = 0;
  List<_HudModuleSlot> _moduleSlots = const [];
  String _moduleLayoutFingerprint = '';

  double _targetZoom = 1.0;
  final double _minZoom = 0.01;
  final double _maxZoom = 1;
  final double _zoomResponse = 10.0;
  final double _worldFitPadding = 1000.0;

  ShipComponent? get player =>
      _playerShipId == null ? null : _shipsById[_playerShipId!];

  void setBattleContext({int? playerShipId, int? matchId}) {
    if (playerShipId != null) {
      _playerShipId = playerShipId;
    }
    if (matchId != null) {
      _lastServerMatchId = matchId;
    }
  }

  Future<void> applyServerState(Map<String, dynamic> event) async {
    final shipsRaw = event['ships'];
    if (shipsRaw is! List) return;

    _lastServerMatchId =
        (event['matchId'] as num?)?.toInt() ?? _lastServerMatchId;
    _lastServerRemainingSec =
        (event['remainingSec'] as num?)?.toInt() ?? _lastServerRemainingSec;
    final seen = <int>{};
    for (final raw in shipsRaw) {
      if (raw is! Map) continue;
      final s = Map<String, dynamic>.from(raw);
      final id = (s['id'] as num?)?.toInt();
      final x = (s['x'] as num?)?.toDouble();
      final y = (s['y'] as num?)?.toDouble();
      final vx = (s['vx'] as num?)?.toDouble() ?? 0;
      final vy = (s['vy'] as num?)?.toDouble() ?? 0;
      if (id == null || x == null || y == null) continue;

      seen.add(id);
      var ship = _shipsById[id];
      if (ship == null) {
        ship = ShipComponent(
          index: id,
          isPlayer: _playerShipId == id,
          onTap: _onShipTapped,
        );
        _shipsById[id] = ship;
        world.add(ship);
      }

      ship
        ..position = Vector2(x, y)
        ..velocity = Vector2(vx, vy)
        ..target = null;
      if (ship.velocity.length2 > 1e-6) {
        ship.angleRad = math.atan2(ship.velocity.y, ship.velocity.x);
        ship.angle = ship.angleRad;
      }
      if (_playerShipId == id) {
        _consumeRuntimeState(s['runtime']);
      }
    }

    final removeIds = _shipsById.keys
        .where((id) => !seen.contains(id))
        .toList();
    for (final id in removeIds) {
      final ship = _shipsById.remove(id);
      ship?.removeFromParent();
      if (lastTappedShip != null && lastTappedShip!.index == id) {
        lastTappedShip = null;
      }
    }
  }

  Future<void> movePlayerTo(Vector2 worldPos) async {
    if (_playerShipId == null) return;
    await network.sendMoveCommand(
      shipId: _playerShipId!,
      x: worldPos.x,
      y: worldPos.y,
    );
    _actionNote =
        'action: move to ${worldPos.x.toStringAsFixed(0)},${worldPos.y.toStringAsFixed(0)}';
  }

  @override
  Future<void> onLoad() async {
    final arenaRadius = BattleRules.arenaRadiusMeters;
    camera.setBounds(
      Rectangle.fromLTWH(
        -arenaRadius,
        -arenaRadius,
        BattleRules.arenaDiameterMeters,
        BattleRules.arenaDiameterMeters,
      ),
      considerViewport: true,
    );
    camera.viewfinder.anchor = Anchor.center;
    camera.viewfinder.zoom = _targetZoom;

    _zoomHud = TextComponent(
      text: 'zoom: ${camera.viewfinder.zoom.toStringAsFixed(2)}',
      position: Vector2(8, 8),
      anchor: Anchor.topLeft,
      textRenderer: TextPaint(
        style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 14),
      ),
    );
    camera.viewport.add(_zoomHud);

    _battleHud = TextComponent(
      text: 'targets: none',
      anchor: Anchor.topRight,
      textRenderer: TextPaint(
        style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 14),
      ),
    );
    camera.viewport.add(_battleHud);

    _infoPanel = RectangleComponent(
      paint: Paint()..color = const Color(0xFF20232A),
    );
    _infoText = TextComponent(
      text: 'selected ship: none',
      position: Vector2(12, 8),
      anchor: Anchor.topLeft,
      textRenderer: TextPaint(
        style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 14),
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
    _customRadiusLabel = _customRadiusButton.button!.children
        .whereType<TextComponent>()
        .first;
    _infoPanel.add(_customRadiusButton);

    camera.viewport.add(_infoPanel);
    _uiReady = true;
    _layoutInfoPanel();
  }

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    if (_uiReady) {
      _layoutInfoPanel();
    }
    if (!_didInitialWorldFit) {
      _fitToBattlefield();
      _didInitialWorldFit = true;
    }
  }

  void _layoutInfoPanel() {
    if (!_uiReady) return;
    final viewportSize = camera.viewport.virtualSize;
    if (viewportSize.x == 0 || viewportSize.y == 0) return;
    _battleHud.position = Vector2(viewportSize.x - 8, 8);
    final panelHeight = viewportSize.y * 0.2;
    _infoPanel
      ..size = Vector2(viewportSize.x, panelHeight)
      ..position = Vector2(0, viewportSize.y - panelHeight)
      ..anchor = Anchor.topLeft;

    _infoText.position = Vector2(12, 8);
    final buttonSize = _moveToButton.size;
    _moveToButton.position = Vector2(_infoPanel.size.x - buttonSize.x - 12, 8);
    _moveToLabel.position = buttonSize / 2;

    final orbitSize = _orbitButton.size;
    _orbitButton.position = Vector2(
      _moveToButton.position.x - orbitSize.x - 12,
      8,
    );
    _orbitLabel.position = orbitSize / 2;

    var moduleX = _orbitButton.position.x - 8;
    for (var i = _moduleButtons.length - 1; i >= 0; i--) {
      final button = _moduleButtons[i];
      final label = _moduleButtonLabels[i];
      moduleX -= button.size.x;
      button.position = Vector2(moduleX, 8);
      label.position = button.size / 2;
      moduleX -= 8;
    }
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

  void _fitToBattlefield() {
    final viewportSize = camera.viewport.virtualSize;
    if (viewportSize.x == 0 || viewportSize.y == 0) return;
    final width = BattleRules.arenaDiameterMeters + _worldFitPadding * 2;
    final height = BattleRules.arenaDiameterMeters + _worldFitPadding * 2;
    final center = Vector2.zero();

    final zoomX = viewportSize.x / width;
    final zoomY = viewportSize.y / height;
    _targetZoom = math.min(zoomX, zoomY).clamp(_minZoom, _maxZoom);
    camera.viewfinder.zoom = _targetZoom;
    camera.viewfinder.position = center;
  }

  @override
  void onScroll(PointerScrollInfo info) {
    final delta = info.scrollDelta.global.y;
    final factor = 1 - delta * 0.001;
    _targetZoom = (_targetZoom * factor).clamp(_minZoom, _maxZoom);
  }

  void _onShipTapped(ShipComponent ship) {
    lastTappedShip = ship;
  }

  Future<void> _onMoveToPressed() async {
    final myShip = player;
    if (myShip == null || lastTappedShip == null) {
      _actionNote = 'action: move to (no target)';
      return;
    }
    await network.sendMoveCommand(
      shipId: _playerShipId!,
      x: lastTappedShip!.position.x,
      y: lastTappedShip!.position.y,
    );
    _actionNote = 'action: move to ship ${lastTappedShip!.index}';
  }

  Future<void> _onOrbitPressed() async {
    if (_playerShipId == null || lastTappedShip == null) {
      _actionNote = 'action: orbit (no target)';
      return;
    }
    await network.sendOrbitCommand(
      shipId: _playerShipId!,
      targetId: lastTappedShip!.index,
      radius: _orbitRadius,
    );
    _actionNote =
        'action: orbit ship ${lastTappedShip!.index} r=${_orbitRadius.toStringAsFixed(0)}';
  }

  @override
  void update(double dt) {
    super.update(dt);

    final current = camera.viewfinder.zoom;
    final t = 1 - math.exp(-_zoomResponse * dt);
    camera.viewfinder.zoom = current + (_targetZoom - current) * t;

    final myShip = player;
    if (myShip != null) {
      final pScreen = camera.localToGlobal(myShip.position);
      _zoomHud.text = [
        'match: ${_lastServerMatchId ?? "-"}  t=${_lastServerRemainingSec}s',
        'zoom: ${camera.viewfinder.zoom.toStringAsFixed(2)}',
        'player id: ${myShip.index}',
        'player world: ${myShip.position.x.toStringAsFixed(1)}, ${myShip.position.y.toStringAsFixed(1)}',
        'player screen: ${pScreen.x.toStringAsFixed(1)}, ${pScreen.y.toStringAsFixed(1)}',
      ].join('\n');
    } else {
      _zoomHud.text = [
        'match: ${_lastServerMatchId ?? "-"}  t=${_lastServerRemainingSec}s',
        'zoom: ${camera.viewfinder.zoom.toStringAsFixed(2)}',
        'waiting server state...',
      ].join('\n');
    }

    final enemies = _shipsInBattle();
    if (enemies.isEmpty || myShip == null) {
      _battleHud.text = 'targets: none';
    } else {
      final lines = <String>['targets (${enemies.length}):'];
      for (final ship in enemies) {
        final distance = (ship.position - myShip.position).length;
        final omega = _relativeAngularSpeed(myShip, ship);
        lines.add(
          '#${ship.index} d=${distance.toStringAsFixed(1)}m  w=${omega.toStringAsFixed(4)}rad/s',
        );
      }
      _battleHud.text = lines.join('\n');
    }

    _infoText.text = lastTappedShip == null
        ? 'selected ship: none'
        : 'selected ship index: ${lastTappedShip!.index}';
    _infoText.text +=
        '\nshield ${_playerShield.toStringAsFixed(1)} armor ${_playerArmor.toStringAsFixed(1)} cap ${_playerCapacitor.toStringAsFixed(1)}';
    _refreshModuleButtonLabels();
    if (_actionNote.isNotEmpty) {
      _infoText.text += '\n$_actionNote';
    }
  }

  void setOrbitRadius(double radius) {
    if (radius <= 0) return;
    _orbitRadius = radius;
    _actionNote = 'orbit radius: ${_orbitRadius.toStringAsFixed(0)}';
  }

  List<ShipComponent> _shipsInBattle() {
    final myShip = player;
    if (myShip == null) return const [];
    return _shipsById.values
        .where((ship) => !identical(ship, myShip))
        .toList(growable: false);
  }

  double _relativeAngularSpeed(ShipComponent source, ShipComponent target) {
    final r = target.position - source.position;
    final v = target.velocity - source.velocity;
    final r2 = (r.x * r.x) + (r.y * r.y);
    if (r2 < 1e-9) return 0.0;
    final cross = (r.x * v.y) - (r.y * v.x);
    return cross / r2;
  }

  void _consumeRuntimeState(dynamic runtimeRaw) {
    if (runtimeRaw is! Map) return;
    final runtime = Map<String, dynamic>.from(runtimeRaw);
    _playerShield = (runtime['shield'] as num?)?.toDouble() ?? _playerShield;
    _playerArmor = (runtime['armor'] as num?)?.toDouble() ?? _playerArmor;
    _playerCapacitor =
        (runtime['capacitor'] as num?)?.toDouble() ?? _playerCapacitor;
    final modulesRaw = runtime['modules'];
    if (modulesRaw is! List) {
      _moduleSlots = const [];
      _rebuildModuleHudIfNeeded('');
      return;
    }
    final next = <_HudModuleSlot>[];
    for (final m in modulesRaw) {
      if (m is! Map) continue;
      final module = Map<String, dynamic>.from(m);
      final moduleId = (module['moduleId'] as String? ?? '').toLowerCase();
      final moduleRef = (module['moduleRef'] as String? ?? '').toLowerCase();
      final slot = (module['slot'] as String? ?? '').toLowerCase();
      if (moduleId.isEmpty || moduleRef.isEmpty || slot.isEmpty) continue;
      final index = _slotIndexFromRef(moduleRef);
      next.add(
        _HudModuleSlot(
          moduleId: moduleId,
          moduleRef: moduleRef,
          slot: slot,
          index: index,
          active: module['active'] == true,
        ),
      );
    }
    next.sort((a, b) {
      final slotCmp = _slotWeight(a.slot).compareTo(_slotWeight(b.slot));
      if (slotCmp != 0) return slotCmp;
      return a.index.compareTo(b.index);
    });
    final fingerprint = next.map((m) => '${m.slot}:${m.index}:${m.moduleId}').join('|');
    _moduleSlots = next;
    _rebuildModuleHudIfNeeded(fingerprint);
  }

  int _slotIndexFromRef(String moduleRef) {
    final parts = moduleRef.split(':');
    if (parts.length != 2) return 0;
    return int.tryParse(parts[1]) ?? 0;
  }

  int _slotWeight(String slot) {
    if (slot == 'high') return 0;
    if (slot == 'mid') return 1;
    if (slot == 'low') return 2;
    return 3;
  }

  void _rebuildModuleHudIfNeeded(String newFingerprint) {
    if (newFingerprint == _moduleLayoutFingerprint && _moduleButtons.isNotEmpty) {
      return;
    }
    _moduleLayoutFingerprint = newFingerprint;
    _rebuildModuleHud();
  }

  void _rebuildModuleHud() {
    for (final button in _moduleButtons) {
      button.removeFromParent();
    }
    _moduleButtons.clear();
    _moduleButtonLabels.clear();

    for (final module in _moduleSlots) {
      final button = _makePanelButton(
        label: _moduleHudLabel(module),
        onPressed: () => _onModulePressed(module.moduleRef),
        width: 96,
      );
      final label = button.button!.children.whereType<TextComponent>().first;
      _moduleButtons.add(button);
      _moduleButtonLabels.add(label);
      _infoPanel.add(button);
    }
    if (_uiReady) {
      _layoutInfoPanel();
    }
  }

  Future<void> _onModulePressed(String moduleRef) async {
    if (_playerShipId == null) return;
    _HudModuleSlot? module;
    for (final m in _moduleSlots) {
      if (m.moduleRef == moduleRef) {
        module = m;
        break;
      }
    }
    if (module == null) return;

    final nextActive = !module.active;
    int? targetId;
    if (nextActive && _isTargetedModuleId(module.moduleId)) {
      if (lastTappedShip == null) {
        _actionNote = 'target is not selected for ${_moduleShortName(module.moduleId)}';
        return;
      }
      targetId = lastTappedShip!.index;
    }

    await network.sendModuleSetCommand(
      shipId: _playerShipId!,
      moduleId: module.moduleId,
      moduleRef: module.moduleRef,
      active: nextActive,
      targetId: targetId,
    );
    _actionNote = nextActive
        ? '${_moduleShortName(module.moduleId)} on${targetId != null ? " -> $targetId" : ""}'
        : '${_moduleShortName(module.moduleId)} off';
  }

  bool _isTargetedModuleId(String moduleId) {
    return moduleId == 'light_blaster_i' ||
        moduleId == 'small_railgun_i' ||
        moduleId == 'stasis_web_i';
  }

  String _moduleShortName(String moduleId) {
    if (moduleId == 'light_blaster_i') return 'blaster';
    if (moduleId == 'small_railgun_i') return 'railgun';
    if (moduleId == 'stasis_web_i') return 'web';
    if (moduleId == 'afterburner_i') return 'ab';
    if (moduleId == 'damage_control_i') return 'dc';
    if (moduleId == 'magnetic_field_stabilizer_i') return 'mfs';
    return moduleId;
  }

  String _slotLabel(String slot, int index) {
    final prefix = slot.isEmpty ? '?' : slot[0].toUpperCase();
    return '$prefix${index + 1}';
  }

  String _moduleHudLabel(_HudModuleSlot module) {
    final activeSuffix = module.active ? '*' : '';
    return '${_slotLabel(module.slot, module.index)} ${_moduleShortName(module.moduleId)}$activeSuffix';
  }

  void _refreshModuleButtonLabels() {
    final count = math.min(_moduleSlots.length, _moduleButtonLabels.length);
    for (var i = 0; i < count; i++) {
      _moduleButtonLabels[i].text = _moduleHudLabel(_moduleSlots[i]);
    }
  }

  void _addRadiusButton(String label, double radius) {
    final button = _makePanelButton(
      label: label,
      onPressed: () => setOrbitRadius(radius),
      width: 52,
    );
    _radiusButtons.add(button);
    _radiusLabels.add(button.button!.children.whereType<TextComponent>().first);
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
    return ButtonComponent(
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
  }

  void _openRadiusInput() {
    overlays.add('radiusInput');
  }

  @override
  void onPanUpdate(DragUpdateInfo info) {
    final delta = info.delta.global;
    final zoom = camera.viewfinder.zoom;
    camera.viewfinder.position -= delta / zoom;
  }

  @override
  void onDoubleTapDown(TapDownInfo info) {
    final worldPos = camera.globalToLocal(info.eventPosition.widget);
    movePlayerTo(worldPos);
  }
}

class _HudModuleSlot {
  final String moduleId;
  final String moduleRef;
  final String slot;
  final int index;
  final bool active;

  const _HudModuleSlot({
    required this.moduleId,
    required this.moduleRef,
    required this.slot,
    required this.index,
    required this.active,
  });
}
