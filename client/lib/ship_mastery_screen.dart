import 'package:flutter/material.dart';
import 'networkclient.dart';

class ShipMasteryScreen extends StatefulWidget {
  const ShipMasteryScreen({super.key, required this.accountEmail});

  final String accountEmail;

  @override
  State<ShipMasteryScreen> createState() => _ShipMasteryScreenState();
}

class _ShipMasteryScreenState extends State<ShipMasteryScreen> {
  final NetworkClient _network = NetworkClient.instance;
  bool _loading = true;
  bool _busy = false;
  int _freeXp = 0;
  String _status = 'Loading mastery data...';
  List<Map<String, dynamic>> _catalog = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final payload = await _network.fetchHangarRoom();
    if (!mounted) return;
    final ok = payload['ok'] == true;
    if (!ok) {
      setState(() {
        _loading = false;
        _status = 'Load failed: ${payload['reason'] ?? "unknown"}';
      });
      return;
    }
    final catalog = (payload['shipCatalog'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
    setState(() {
      _loading = false;
      _freeXp = (payload['freeXp'] as num?)?.toInt() ?? 0;
      _catalog = catalog;
      _status = 'Ready';
    });
  }

  Future<void> _unlock(String hull) async {
    if (_busy) return;
    setState(() => _busy = true);
    final response = await _network.unlockShipMastery(hull);
    if (!mounted) return;
    final ok = response['ok'] == true;
    if (!ok) {
      setState(() {
        _busy = false;
        _status = 'Unlock failed: ${response['reason'] ?? "unknown"}';
      });
      return;
    }
    setState(() {
      _busy = false;
      _status = response['alreadyMastered'] == true
          ? '$hull already mastered'
          : '$hull mastered';
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ship Mastery')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Pilot: ${widget.accountEmail}'),
                  const SizedBox(height: 4),
                  Text('Free XP: $_freeXp'),
                  const SizedBox(height: 4),
                  Text('Status: $_status'),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _catalog.isEmpty
                        ? const Text('No ships in mastery catalog')
                        : ListView.builder(
                            itemCount: _catalog.length,
                            itemBuilder: (context, index) {
                              final item = _catalog[index];
                              final hull = '${item['hull']}';
                              final name = '${item['name']}';
                              final shipClass = '${item['class']}';
                              final cost =
                                  (item['masteryXpCost'] as num?)?.toInt() ?? 0;
                              final mastered = item['mastered'] == true;
                              final canUnlock =
                                  !mastered && !_busy && _freeXp >= cost;
                              return Card(
                                child: ListTile(
                                  title: Text(name),
                                  subtitle: Text(
                                    'hull=$hull class=$shipClass cost=${cost}XP',
                                  ),
                                  trailing: mastered
                                      ? const Text('Mastered')
                                      : FilledButton(
                                          onPressed: canUnlock
                                              ? () => _unlock(hull)
                                              : null,
                                          child: const Text('Unlock'),
                                        ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
    );
  }
}
