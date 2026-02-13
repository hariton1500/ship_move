import 'package:flutter/material.dart';
import 'networkclient.dart';

class ShipFittingScreen extends StatefulWidget {
  const ShipFittingScreen({super.key, required this.accountEmail});

  final String accountEmail;

  @override
  State<ShipFittingScreen> createState() => _ShipFittingScreenState();
}

class _ShipFittingScreenState extends State<ShipFittingScreen> {
  final NetworkClient _network = NetworkClient.instance;
  bool _loading = true;
  bool _busy = false;
  String _status = 'Loading ships...';
  List<Map<String, dynamic>> _ships = const [];
  String? _selectedShipId;
  Map<String, dynamic>? _selectedShip;
  List<Map<String, dynamic>> _moduleCatalog = const [];
  Map<String, dynamic> _hullStats = const {};

  @override
  void initState() {
    super.initState();
    _loadShips();
  }

  Future<void> _loadShips() async {
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
      _ships = ships;
      _status = ships.isEmpty ? 'No ships in hangar' : 'Select ship';
      if (ships.isNotEmpty) {
        _selectedShipId = (ships.first['id'] as String?) ?? '';
      }
    });
    if (_selectedShipId != null && _selectedShipId!.isNotEmpty) {
      await _loadFitting(_selectedShipId!);
    }
  }

  Future<void> _loadFitting(String shipId) async {
    final response = await _network.fetchShipFitting(shipId);
    if (!mounted) return;
    if (response['ok'] != true) {
      setState(() {
        _status = 'Fitting load failed: ${response['reason'] ?? "unknown"}';
      });
      return;
    }
    final ship = Map<String, dynamic>.from(response['ship'] as Map);
    final modules = (response['moduleCatalog'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
    setState(() {
      _selectedShipId = shipId;
      _selectedShip = ship;
      _moduleCatalog = modules;
      _hullStats = Map<String, dynamic>.from(response['hullStats'] as Map);
      _status = 'Fitting loaded';
    });
  }

  Future<void> _installModule(String moduleId) async {
    if (_selectedShipId == null || _busy) return;
    setState(() => _busy = true);
    final response = await _network.installModule(
      shipId: _selectedShipId!,
      moduleId: moduleId,
    );
    if (!mounted) return;
    if (response['ok'] != true) {
      setState(() {
        _busy = false;
        _status = 'Install failed: ${response['reason'] ?? "unknown"}';
      });
      return;
    }
    setState(() {
      _busy = false;
      _selectedShip = Map<String, dynamic>.from(response['ship'] as Map);
      _status = 'Module installed';
    });
  }

  Future<void> _removeModule(String slot, int index) async {
    if (_selectedShipId == null || _busy) return;
    setState(() => _busy = true);
    final response = await _network.removeModule(
      shipId: _selectedShipId!,
      slot: slot,
      index: index,
    );
    if (!mounted) return;
    if (response['ok'] != true) {
      setState(() {
        _busy = false;
        _status = 'Remove failed: ${response['reason'] ?? "unknown"}';
      });
      return;
    }
    setState(() {
      _busy = false;
      _selectedShip = Map<String, dynamic>.from(response['ship'] as Map);
      _status = 'Module removed';
    });
  }

  List<Map<String, dynamic>> _modulesForSlot(String slot) {
    return _moduleCatalog
        .where((m) => m['slot'] == slot)
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ship Fitting')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Pilot: ${widget.accountEmail}'),
                  const SizedBox(height: 4),
                  Text('Status: $_status'),
                  const SizedBox(height: 8),
                  DropdownButton<String>(
                    value: _selectedShipId,
                    isExpanded: true,
                    hint: const Text('Select ship'),
                    items: _ships
                        .map(
                          (s) => DropdownMenuItem<String>(
                            value: s['id'] as String?,
                            child: Text('${s['name']} (${s['id']})'),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) {
                      if (value == null) return;
                      _loadFitting(value);
                    },
                  ),
                  const SizedBox(height: 8),
                  if (_selectedShip != null) ...[
                    _buildShipResources(),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(child: _buildCurrentFitting()),
                          const SizedBox(width: 12),
                          Expanded(child: _buildModuleCatalog()),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildShipResources() {
    final fitting = Map<String, dynamic>.from(
      _selectedShip?['fitting'] as Map? ?? const {},
    );
    final usedCpu = fitting['usedCpu'] ?? 0;
    final usedPower = fitting['usedPower'] ?? 0;
    final maxCpu = _hullStats['cpu'] ?? 0;
    final maxPower = _hullStats['power'] ?? 0;
    return Text('CPU: $usedCpu/$maxCpu   Power: $usedPower/$maxPower');
  }

  Widget _buildCurrentFitting() {
    final fitting = Map<String, dynamic>.from(
      _selectedShip?['fitting'] as Map? ?? const {},
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Current Fitting',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            children: [
              _buildSlotList('high', fitting),
              _buildSlotList('mid', fitting),
              _buildSlotList('low', fitting),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSlotList(String slot, Map<String, dynamic> fitting) {
    final modules = (fitting[slot] as List? ?? const []).cast<String>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('$slot slots (${modules.length})'),
            const SizedBox(height: 4),
            if (modules.isEmpty) const Text('empty'),
            for (var i = 0; i < modules.length; i++)
              Row(
                children: [
                  Expanded(child: Text(modules[i])),
                  TextButton(
                    onPressed: _busy ? null : () => _removeModule(slot, i),
                    child: const Text('Remove'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildModuleCatalog() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Module Catalog',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            children: [
              _buildModuleSlotSection('high'),
              _buildModuleSlotSection('mid'),
              _buildModuleSlotSection('low'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildModuleSlotSection(String slot) {
    final modules = _modulesForSlot(slot);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('$slot modules'),
            const SizedBox(height: 4),
            if (modules.isEmpty) const Text('none'),
            for (final m in modules)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${m['name']} cpu=${m['cpu']} pwr=${m['power']}',
                    ),
                  ),
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _installModule('${m['id']}'),
                    child: const Text('Install'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
