import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class MissionProgressStore {
  MissionProgressStore({SharedPreferences? preferences})
      : _preferences = preferences;

  static const String storageKey = 'daily_mission_progress_v1';

  SharedPreferences? _preferences;

  Future<Map<int, bool>> readOverrides({
    required int userId,
    required DateTime day,
  }) async {
    final records = await _readRecords();
    final raw = records[_scope(userId, day)];
    if (raw is! Map) return <int, bool>{};

    final result = <int, bool>{};
    for (final entry in raw.entries) {
      final taskId = int.tryParse(entry.key.toString());
      if (taskId != null && entry.value is bool) {
        result[taskId] = entry.value as bool;
      }
    }
    return result;
  }

  Future<void> setOverride({
    required int userId,
    required DateTime day,
    required int taskId,
    required bool completed,
  }) async {
    final records = await _readRecords();
    final scope = _scope(userId, day);
    final scoped = records[scope] is Map
        ? Map<String, dynamic>.from(records[scope] as Map)
        : <String, dynamic>{};
    scoped[taskId.toString()] = completed;
    records
      ..removeWhere((key, _) => !_isCurrentScope(key, userId, day))
      ..[scope] = scoped;
    await _writeRecords(records);
  }

  Future<void> clearOverride({
    required int userId,
    required DateTime day,
    required int taskId,
  }) async {
    final records = await _readRecords();
    final scope = _scope(userId, day);
    final raw = records[scope];
    if (raw is! Map) return;
    final scoped = Map<String, dynamic>.from(raw)..remove(taskId.toString());
    if (scoped.isEmpty) {
      records.remove(scope);
    } else {
      records[scope] = scoped;
    }
    await _writeRecords(records);
  }

  Future<Map<String, dynamic>> _readRecords() async {
    final preferences = _preferences ??= await SharedPreferences.getInstance();
    final raw = preferences.getString(storageKey);
    if (raw == null || raw.trim().isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } on FormatException {
      return <String, dynamic>{};
    }
  }

  Future<void> _writeRecords(Map<String, dynamic> records) async {
    final preferences = _preferences ??= await SharedPreferences.getInstance();
    await preferences.setString(storageKey, jsonEncode(records));
  }

  static String _scope(int userId, DateTime day) {
    final localDay = day.toLocal();
    final date = [
      localDay.year.toString().padLeft(4, '0'),
      localDay.month.toString().padLeft(2, '0'),
      localDay.day.toString().padLeft(2, '0'),
    ].join('-');
    return '$userId:$date';
  }

  static bool _isCurrentScope(String scope, int userId, DateTime day) {
    return scope == _scope(userId, day);
  }
}
