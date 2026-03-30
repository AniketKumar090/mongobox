import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'env_config.dart';

class VoiceBackendBootstrapResult {
  const VoiceBackendBootstrapResult({
    required this.isHealthy,
    this.didStart = false,
    this.message,
  });

  final bool isHealthy;
  final bool didStart;
  final String? message;
}

class VoiceBackendBootstrapService {
  VoiceBackendBootstrapService._();

  static final http.Client _client = http.Client();
  static const MethodChannel _launcherChannel = MethodChannel(
    'com.example.mongobox/voice_backend_launcher',
  );
  static DateTime? _lastStartAttemptAt;

  static Future<VoiceBackendBootstrapResult> ensureBackendReady() async {
    final backendUrl = EnvConfig.voiceBackendUrl;
    if (await _isBackendHealthy(backendUrl)) {
      return const VoiceBackendBootstrapResult(isHealthy: true);
    }

    final uri = Uri.tryParse(backendUrl);
    if (!_canAutoStart(uri)) {
      return VoiceBackendBootstrapResult(
        isHealthy: false,
        message:
            'Voice backend is offline. Start it with: cd voice-backend && python start.py',
      );
    }

    final now = DateTime.now();
    if (_lastStartAttemptAt != null &&
        now.difference(_lastStartAttemptAt!) < const Duration(seconds: 12)) {
      return const VoiceBackendBootstrapResult(
        isHealthy: false,
        didStart: true,
        message: 'Voice backend is still starting in the background…',
      );
    }

    final startScript = _findBackendStartScript();
    if (startScript == null) {
      return VoiceBackendBootstrapResult(
        isHealthy: false,
        message:
            'Voice backend is offline and the local start script could not be found.',
      );
    }

    final didStart = await _startBackend(uri!);
    if (!didStart) {
      return VoiceBackendBootstrapResult(
        isHealthy: false,
        message:
            'Voice backend is offline. Start it with: cd voice-backend && python start.py',
      );
    }

    _lastStartAttemptAt = now;
    return const VoiceBackendBootstrapResult(
      isHealthy: false,
      didStart: true,
      message: 'Starting voice backend in the background…',
    );
  }

  static Future<bool> _isBackendHealthy(String backendUrl) async {
    try {
      final response = await _client
          .get(
            Uri.parse('${backendUrl.replaceFirst(RegExp(r'/+$'), '')}/health'),
          )
          .timeout(const Duration(milliseconds: 1200));

      if (response.statusCode != 200) return false;

      final decoded = json.decode(response.body);
      if (decoded is Map<String, dynamic>) {
        return decoded['status'] == 'ok';
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  static bool _canAutoStart(Uri? uri) {
    if (kIsWeb || uri == null || uri.scheme != 'http') return false;
    if (!(Platform.isMacOS ||
        Platform.isLinux ||
        Platform.isWindows ||
        Platform.isIOS)) {
      return false;
    }

    const localHosts = {'127.0.0.1', 'localhost', '::1'};
    return localHosts.contains(uri.host);
  }

  static Future<bool> _startBackend(Uri uri) async {
    if (Platform.isIOS) {
      return _startBackendViaNativeLauncher(uri);
    }

    final startScript = _findBackendStartScript();
    if (startScript == null) return false;
    return _startBackendProcess(uri, startScript);
  }

  static File? _findBackendStartScript() {
    Directory current = Directory.current.absolute;

    for (var i = 0; i < 6; i++) {
      final direct = File('${current.path}/voice-backend/start.py');
      if (direct.existsSync()) return direct;

      final nested = File('${current.path}/start.py');
      if (current.path.endsWith('/voice-backend') && nested.existsSync()) {
        return nested;
      }

      final parent = current.parent;
      if (parent.path == current.path) break;
      current = parent;
    }

    return null;
  }

  static Future<bool> _startBackendProcess(Uri uri, File startScript) async {
    final workingDirectory = startScript.parent;
    final pythonExecutable = _resolvePythonExecutable(workingDirectory);
    final args = <String>[
      startScript.path,
      '--skip-install',
      '--host',
      uri.host,
      '--port',
      '${uri.hasPort ? uri.port : 8000}',
    ];

    try {
      await Process.start(
        pythonExecutable,
        args,
        workingDirectory: workingDirectory.path,
        mode: ProcessStartMode.detached,
      );
      debugPrint(
        '[VoiceBackendBootstrap] Started backend using $pythonExecutable',
      );
      return true;
    } catch (e, st) {
      debugPrint('[VoiceBackendBootstrap] Failed to start backend: $e');
      debugPrint('$st');
      return false;
    }
  }

  static Future<bool> _startBackendViaNativeLauncher(Uri uri) async {
    try {
      final started = await _launcherChannel.invokeMethod<bool>(
        'startVoiceBackend',
        <String, dynamic>{
          'host': uri.host,
          'port': uri.hasPort ? uri.port : 8000,
        },
      );
      return started ?? false;
    } on PlatformException catch (e) {
      debugPrint(
        '[VoiceBackendBootstrap] Native launcher failed: ${e.message}',
      );
      return false;
    } on MissingPluginException {
      debugPrint('[VoiceBackendBootstrap] Native launcher not available');
      return false;
    }
  }

  static String _resolvePythonExecutable(Directory backendDir) {
    if (Platform.isWindows) {
      final venvPython = File('${backendDir.path}\\.venv\\Scripts\\python.exe');
      if (venvPython.existsSync()) return venvPython.path;
      return 'python';
    }

    final python3 = File('${backendDir.path}/.venv/bin/python3');
    if (python3.existsSync()) return python3.path;

    final python = File('${backendDir.path}/.venv/bin/python');
    if (python.existsSync()) return python.path;

    return 'python3';
  }
}
