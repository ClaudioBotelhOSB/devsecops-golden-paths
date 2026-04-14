// ============================================================================
// tests/patrol/integration_test/smoke_test.dart
//
// Minimal real Patrol smoke for any service that exposes an HTTP health
// endpoint. Reads BASE_URL, HEALTH_ENDPOINT, and QUARANTINE_FILE via
// --dart-define. Quarantined tests are skipped silently - the list is
// rebuilt nightly by the quarantine-scan job in .github/workflows/e2e.yml.
//
// HONEST SCOPE:
//   This file ships ONE real test: the preview environment responds to
//   an HTTP GET on the configured health path with a status under 400.
//   It does NOT drive any real mobile UI, because this template does not
//   know what your mobile app looks like.
//
//   Extend this file with patrolTest(...) blocks that actually drive
//   your app before treating the Patrol shard as a production smoke.
// ============================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:patrol/patrol.dart';

const String _baseUrl = String.fromEnvironment(
  'BASE_URL',
  defaultValue: 'https://preview.example.internal',
);
const String _healthEndpoint = String.fromEnvironment(
  'HEALTH_ENDPOINT',
  defaultValue: '/healthz',
);
const String _quarantineFile = String.fromEnvironment(
  'QUARANTINE_FILE',
  defaultValue: '',
);

Set<String> _loadQuarantine() {
  if (_quarantineFile.isEmpty) return <String>{};
  final f = File(_quarantineFile);
  if (!f.existsSync()) return <String>{};
  try {
    final decoded = json.decode(f.readAsStringSync()) as Map<String, dynamic>;
    final list = (decoded['tests'] as List?)?.cast<String>() ?? const <String>[];
    return list.toSet();
  } on FormatException {
    return <String>{};
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final quarantined = _loadQuarantine();

  bool isQuarantined(String testName) =>
      quarantined.contains('smoke_test::$testName');

  patrolTest('preview_health_endpoint_reachable', ($) async {
    if (isQuarantined('preview_health_endpoint_reachable')) return;

    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('$_baseUrl$_healthEndpoint'));
      final res = await req.close();
      expect(res.statusCode, lessThan(400));
    } finally {
      client.close(force: true);
    }
  });
}
