import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

class NetworkResult {
  final bool ok;
  final String? reason;

  const NetworkResult({required this.ok, this.reason});
}

class NetworkClient {
  NetworkClient._();

  static final NetworkClient instance = NetworkClient._();

  WebSocketChannel? _channel;
  final StreamController<Map<String, dynamic>> _eventController =
      StreamController<Map<String, dynamic>>.broadcast();
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  bool _isConnected = false;

  String _serverUrl = 'ws://127.0.0.1:8080';

  Stream<Map<String, dynamic>> get events => _eventController.stream;
  bool get isConnected => _isConnected;
  String get serverUrl => _serverUrl;

  Future<void> connect({String? url}) async {
    if (_isConnected) return;
    if (url != null && url.trim().isNotEmpty) {
      _serverUrl = url.trim();
    }
    _channel = WebSocketChannel.connect(Uri.parse(_serverUrl));
    _channel!.stream.listen(
      _onMessage,
      onError: (error) {
        _isConnected = false;
        _completeAllPendingWithError('connection_error');
      },
      onDone: () {
        _isConnected = false;
        _completeAllPendingWithError('connection_closed');
      },
    );
    _isConnected = true;
  }

  Future<void> disconnect() async {
    await _channel?.sink.close();
    _channel = null;
    _isConnected = false;
  }

  Future<NetworkResult> register({
    required String email,
    required String password,
  }) async {
    await connect();
    final response = await _request(
      key: 'auth:register',
      payload: {'type': 'register', 'email': email, 'password': password},
    );
    return NetworkResult(
      ok: response['ok'] == true,
      reason: response['reason'] as String?,
    );
  }

  Future<NetworkResult> login({
    required String email,
    required String password,
  }) async {
    await connect();
    final response = await _request(
      key: 'auth:login',
      payload: {'type': 'login', 'email': email, 'password': password},
    );
    return NetworkResult(
      ok: response['ok'] == true,
      reason: response['reason'] as String?,
    );
  }

  Future<NetworkResult> joinQueue({
    required String mode,
    int shipPoints = 10,
  }) async {
    final response = await _request(
      key: 'queue:join',
      payload: {'type': 'queue_join', 'mode': mode, 'shipPoints': shipPoints},
    );
    return NetworkResult(
      ok: response['ok'] == true,
      reason: response['reason'] as String?,
    );
  }

  Future<NetworkResult> leaveQueue() async {
    final response = await _request(
      key: 'queue:leave',
      payload: {'type': 'queue_leave'},
    );
    return NetworkResult(
      ok: response['ok'] == true,
      reason: response['reason'] as String?,
    );
  }

  void _onMessage(dynamic raw) {
    final decoded = jsonDecode(raw as String);
    if (decoded is! Map) return;
    final message = Map<String, dynamic>.from(decoded);

    final type = message['type'] as String?;
    final action = message['action'] as String?;
    if (type == 'auth' && action != null) {
      _completePending('auth:$action', message);
      return;
    }
    if (type == 'queue' && action != null) {
      _completePending('queue:$action', message);
      return;
    }

    _eventController.add(message);
  }

  Future<Map<String, dynamic>> _request({
    required String key,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    await connect();
    if (_channel == null) {
      return {'ok': false, 'reason': 'not_connected'};
    }
    if (_pending.containsKey(key)) {
      return {'ok': false, 'reason': 'request_already_pending'};
    }

    final completer = Completer<Map<String, dynamic>>();
    _pending[key] = completer;
    _channel!.sink.add(jsonEncode(payload));

    try {
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          _pending.remove(key);
          return {'ok': false, 'reason': 'timeout'};
        },
      );
    } catch (_) {
      _pending.remove(key);
      return {'ok': false, 'reason': 'internal_error'};
    }
  }

  void _completePending(String key, Map<String, dynamic> message) {
    final completer = _pending.remove(key);
    if (completer != null && !completer.isCompleted) {
      completer.complete(message);
    }
  }

  void _completeAllPendingWithError(String reason) {
    final keys = _pending.keys.toList(growable: false);
    for (final key in keys) {
      final completer = _pending.remove(key);
      if (completer != null && !completer.isCompleted) {
        completer.complete({'ok': false, 'reason': reason});
      }
    }
  }
}
