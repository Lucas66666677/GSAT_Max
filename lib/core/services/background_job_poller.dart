import 'dart:async';

typedef BackgroundJobFetcher = Future<Map<String, dynamic>> Function(
  String jobId,
);

class BackgroundJobFailed implements Exception {
  const BackgroundJobFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

class BackgroundJobPoller {
  const BackgroundJobPoller({
    this.pollInterval = const Duration(seconds: 2),
    this.maxAttempts = 50,
    this.delay = Future.delayed,
  });

  final Duration pollInterval;
  final int maxAttempts;
  final Future<void> Function(Duration duration) delay;

  Future<Map<String, dynamic>> waitForCompletion({
    required Map<String, dynamic> initialJob,
    required BackgroundJobFetcher fetch,
    void Function(String status)? onStatus,
  }) async {
    var job = Map<String, dynamic>.from(initialJob);
    final jobId = (job['id'] ?? '').toString().trim();
    if (jobId.isEmpty) {
      throw const FormatException('Background job response is missing an id.');
    }

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final status = (job['status'] ?? 'queued').toString().toLowerCase();
      onStatus?.call(status);
      if (status == 'completed') return job;
      if (status == 'failed') {
        throw BackgroundJobFailed(
          (job['error_message'] ?? 'Background job failed.').toString(),
        );
      }
      await delay(pollInterval);
      job = await fetch(jobId);
    }
    throw TimeoutException(
      'Background job did not finish after $maxAttempts polls.',
    );
  }
}
