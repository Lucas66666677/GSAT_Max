import 'dart:convert';

import 'package:http/http.dart' as http;

typedef AuthenticatedPatchSender = Future<http.Response> Function(
  Uri uri,
  Object body,
);

class TargetExamDateService {
  const TargetExamDateService({required this.endpoint});

  final Uri endpoint;

  Future<DateTime> update({
    required DateTime requestedDate,
    required AuthenticatedPatchSender send,
  }) async {
    final response = await send(
      endpoint,
      jsonEncode({'target_exam_date': requestedDate.toIso8601String()}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
          'Target exam date update failed (${response.statusCode}).');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException(
          'Target exam date response must be an object.');
    }
    final parsed = DateTime.tryParse(
      (decoded['target_exam_date'] ?? '').toString(),
    );
    if (parsed == null) {
      throw const FormatException('Target exam date response is invalid.');
    }
    return parsed;
  }
}
