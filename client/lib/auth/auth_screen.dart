import 'package:flutter/material.dart';
import '../mainscreen.dart';
import 'account_store.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final AccountStore _store = AccountStore();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  List<LocalAccount> _savedAccounts = const [];
  bool _loading = true;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final accounts = await _store.loadAccounts();
    final lastEmail = await _store.loadLastEmail();
    if (!mounted) return;
    setState(() {
      _savedAccounts = accounts;
      if (lastEmail != null && lastEmail.isNotEmpty) {
        _emailController.text = lastEmail;
      }
      _loading = false;
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _status = 'Введите email и пароль.');
      return;
    }
    final ok = await _store.register(email: email, password: password);
    if (!mounted) return;
    if (!ok) {
      setState(() => _status = 'Аккаунт уже существует.');
      return;
    }
    await _load();
    if (!mounted) return;
    setState(() => _status = 'Регистрация успешна.');
    _openGame(email.toLowerCase());
  }

  Future<void> _login() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _status = 'Введите email и пароль.');
      return;
    }
    final ok = await _store.login(email: email, password: password);
    if (!mounted) return;
    if (!ok) {
      setState(() => _status = 'Неверный email или пароль.');
      return;
    }
    setState(() => _status = 'Вход выполнен.');
    _openGame(email.toLowerCase());
  }

  Future<void> _loginSaved(LocalAccount account) async {
    _emailController.text = account.email;
    _passwordController.text = account.password;
    await _store.saveLastEmail(account.email);
    if (!mounted) return;
    _openGame(account.email);
  }

  void _openGame(String email) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => MainScreen(accountEmail: email)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Ship Move: Auth')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Пароль'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _login,
                    child: const Text('Вход'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _register,
                    child: const Text('Регистрация'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_status.isNotEmpty)
              Text(_status, style: const TextStyle(color: Colors.blueGrey)),
            const SizedBox(height: 16),
            const Text(
              'Сохраненные аккаунты',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _savedAccounts.isEmpty
                  ? const Text('Список пуст.')
                  : ListView.builder(
                      itemCount: _savedAccounts.length,
                      itemBuilder: (context, index) {
                        final account = _savedAccounts[index];
                        return ListTile(
                          dense: true,
                          title: Text(account.email),
                          trailing: TextButton(
                            onPressed: () => _loginSaved(account),
                            child: const Text('Войти'),
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
