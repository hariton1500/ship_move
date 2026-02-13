import 'package:flutter/material.dart';
import 'networkclient.dart';

class ShipShopScreen extends StatefulWidget {
  const ShipShopScreen({super.key, required this.accountEmail});

  final String accountEmail;

  @override
  State<ShipShopScreen> createState() => _ShipShopScreenState();
}

class _ShipShopScreenState extends State<ShipShopScreen> {
  final NetworkClient _network = NetworkClient.instance;
  bool _loading = true;
  bool _busy = false;
  int _balance = 0;
  String _status = 'Loading shop...';
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
        _status = 'Shop load failed: ${payload['reason'] ?? "unknown"}';
      });
      return;
    }
    final catalog = (payload['shipCatalog'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
    setState(() {
      _loading = false;
      _balance = (payload['balance'] as num?)?.toInt() ?? 0;
      _catalog = catalog;
      _status = 'Ready';
    });
  }

  Future<void> _buy(String hull) async {
    if (_busy) return;
    setState(() => _busy = true);
    final response = await _network.buyShip(hull);
    if (!mounted) return;
    final ok = response['ok'] == true;
    if (!ok) {
      setState(() {
        _busy = false;
        _status = 'Buy failed: ${response['reason'] ?? "unknown"}';
      });
      return;
    }
    setState(() {
      _busy = false;
      _status = '$hull purchased';
      _balance = (response['balance'] as num?)?.toInt() ?? _balance;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ship Shop')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Pilot: ${widget.accountEmail}'),
                  const SizedBox(height: 4),
                  Text('Balance: $_balance'),
                  const SizedBox(height: 4),
                  Text('Status: $_status'),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _catalog.isEmpty
                        ? const Text('No ships in shop')
                        : ListView.builder(
                            itemCount: _catalog.length,
                            itemBuilder: (context, index) {
                              final item = _catalog[index];
                              final hull = '${item['hull']}';
                              final name = '${item['name']}';
                              final shipClass = '${item['class']}';
                              final mastered = item['mastered'] == true;
                              final price =
                                  (item['shipPrice'] as num?)?.toInt() ?? 0;
                              final canBuy =
                                  mastered && !_busy && _balance >= price;
                              return Card(
                                child: ListTile(
                                  title: Text(name),
                                  subtitle: Text(
                                    'hull=$hull class=$shipClass price=$price mastered=$mastered',
                                  ),
                                  trailing: FilledButton(
                                    onPressed: canBuy ? () => _buy(hull) : null,
                                    child: const Text('Buy'),
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
