import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class LocalAccount {
  final String email;
  final String password;

  const LocalAccount({required this.email, required this.password});

  Map<String, dynamic> toJson() => {'email': email, 'password': password};

  factory LocalAccount.fromJson(Map<String, dynamic> json) {
    return LocalAccount(
      email: json['email'] as String,
      password: json['password'] as String,
    );
  }
}

class AccountStore {
  static const _accountsKey = 'accounts_v1';
  static const _lastEmailKey = 'last_email_v1';

  Future<List<LocalAccount>> loadAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_accountsKey);
    if (raw == null || raw.isEmpty) return [];
    final list = (jsonDecode(raw) as List)
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .map(LocalAccount.fromJson)
        .toList(growable: false);
    return list;
  }

  Future<void> saveAccounts(List<LocalAccount> accounts) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = jsonEncode(accounts.map((a) => a.toJson()).toList());
    await prefs.setString(_accountsKey, payload);
  }

  Future<String?> loadLastEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastEmailKey);
  }

  Future<void> saveLastEmail(String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastEmailKey, email);
  }

  Future<bool> register({
    required String email,
    required String password,
  }) async {
    final normalized = email.trim().toLowerCase();
    final accounts = (await loadAccounts()).toList();
    final exists = accounts.any((a) => a.email.toLowerCase() == normalized);
    if (exists) return false;
    accounts.add(LocalAccount(email: normalized, password: password));
    await saveAccounts(accounts);
    await saveLastEmail(normalized);
    return true;
  }

  Future<bool> login({required String email, required String password}) async {
    final normalized = email.trim().toLowerCase();
    final accounts = await loadAccounts();
    final match = accounts.any(
      (a) => a.email.toLowerCase() == normalized && a.password == password,
    );
    if (!match) return false;
    await saveLastEmail(normalized);
    return true;
  }
}
