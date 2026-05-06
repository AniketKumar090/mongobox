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
    if (await EnvConfig.isPhysicalIosDeviceUsingLocalBackend()) {
      return VoiceBackendBootstrapResult(
        isHealthy: false,
        message: EnvConfig.voiceBackendPhysicalDeviceHelp(),
      );
    }

    final backendUrl = await EnvConfig.resolveVoiceBackendUrl();
    if (await _isBackendHealthy(backendUrl)) {
      return const VoiceBackendBootstrapResult(isHealthy: true);
    }

    final uri = Uri.tryParse(backendUrl);
    if (!_canAutoStart(uri)) {
      return VoiceBackendBootstrapResult(
        isHealthy: false,
        message: _bootstrapHintMessage(uri, backendUrl),
      );
    }

    final now = DateTime.now();
    if (_lastStartAttemptAt != null &&
        now.difference(_lastStartAttemptAt!) < const Duration(seconds: 12)) {
      return const VoiceBackendBootstrapResult(
        isHealthy: false,
        didStart: true,
        message: 'Voice backend process is still starting…',
      );
    }

    if (!Platform.isIOS) {
      final startScript = _findBackendStartScript();
      if (startScript == null) {
        return VoiceBackendBootstrapResult(
          isHealthy: false,
          message: _missingBackendFilesMessage(),
        );
      }
    }

    final didStart = await _startBackend(uri!);
    if (!didStart) {
      return VoiceBackendBootstrapResult(
        isHealthy: false,
        message: _startupFailureMessage(),
      );
    }

    _lastStartAttemptAt = now;
    return const VoiceBackendBootstrapResult(
      isHealthy: false,
      didStart: true,
      message: 'Starting MongoBox voice backend…',
    );
  }

  static Future<VoiceBackendBootstrapResult> ensureBackendReadyAndWait({
    Duration startupTimeout = const Duration(seconds: 10),
    Duration pollInterval = const Duration(milliseconds: 500),
  }) async {
    final initial = await ensureBackendReady();
    if (initial.isHealthy) return initial;

    final backendUrl = await EnvConfig.resolveVoiceBackendUrl();
    final uri = Uri.tryParse(backendUrl);
    if (!_canAutoStart(uri) || startupTimeout <= Duration.zero) {
      return initial;
    }

    final deadline = DateTime.now().add(startupTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(pollInterval);
      if (await _isBackendHealthy(backendUrl)) {
        return VoiceBackendBootstrapResult(
          isHealthy: true,
          didStart: initial.didStart,
          message:
              initial.didStart ? 'Voice backend is ready.' : initial.message,
        );
      }
    }

    return VoiceBackendBootstrapResult(
      isHealthy: false,
      didStart: initial.didStart,
      message: initial.didStart ? _startupTimeoutMessage() : initial.message,
    );
  }

  static Future<VoiceBackendBootstrapResult> waitForBackendReady({
    Duration startupTimeout = const Duration(seconds: 20),
    Duration pollInterval = const Duration(milliseconds: 500),
  }) async {
    final backendUrl = await EnvConfig.resolveVoiceBackendUrl();
    final uri = Uri.tryParse(backendUrl);
    if (!_canAutoStart(uri) || startupTimeout <= Duration.zero) {
      return VoiceBackendBootstrapResult(
        isHealthy: false,
        message: _bootstrapHintMessage(uri, backendUrl),
      );
    }

    final deadline = DateTime.now().add(startupTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(pollInterval);
      if (await _isBackendHealthy(backendUrl)) {
        return const VoiceBackendBootstrapResult(
          isHealthy: true,
          didStart: true,
          message: 'Voice backend is ready.',
        );
      }
    }

    return VoiceBackendBootstrapResult(
      isHealthy: false,
      didStart: true,
      message: _startupTimeoutMessage(),
    );
  }

  static Future<bool> _isBackendHealthy(String backendUrl) async {
    try {
      final response = await _client
          .get(
            Uri.parse('${backendUrl.replaceFirst(RegExp(r'/+$'), '')}/health'),
          )
          .timeout(const Duration(milliseconds: 3000));

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

  /// When the backend URL is not loopback (e.g. Mac LAN IP from a phone), we
  /// cannot look for `voice-backend/` on the device filesystem — show reachability help.
  static String _bootstrapHintMessage(Uri? uri, String backendUrl) {
    if (_isNonLocalBackendHost(uri)) {
      return _remoteBackendUnreachableMessage(backendUrl);
    }

    final startScript = _findBackendStartScript();
    if (startScript == null) {
      if (Platform.isIOS || Platform.isAndroid) {
        return _remoteBackendUnreachableMessage(backendUrl);
      }
      return _missingBackendFilesMessage();
    }
    return _desktopSetupChecklist(startScript.parent);
  }

  static bool _isNonLocalBackendHost(Uri? uri) {
    if (uri == null || uri.host.isEmpty) return false;
    const localHosts = {'127.0.0.1', 'localhost', '::1'};
    return !localHosts.contains(uri.host);
  }

  static String _remoteBackendUnreachableMessage(String backendUrl) {
    final base = backendUrl.replaceFirst(RegExp(r'/+$'), '');
    return 'Could not reach the voice backend at $backendUrl.\n\n'
        'On your Mac (same Wi-Fi as this phone), run:\n'
        '  cd voice-backend && python start.py\n'
        'Then open $base/health in Safari on this phone. If that fails, '
        'verify `VOICE_BACKEND_DEVICE_URL` matches the IP of your Mac and that '
        'macOS firewall allows incoming connections for Python.';
  }

  static String _startupFailureMessage() {
    final startScript = _findBackendStartScript();
    if (startScript == null) {
      return _missingBackendFilesMessage();
    }
    return 'Voice backend could not start automatically.\n\n'
        '${_desktopSetupChecklist(startScript.parent)}';
  }

  static String _startupTimeoutMessage() {
    final startScript = _findBackendStartScript();
    final setupHint =
        startScript == null
            ? _missingBackendFilesMessage()
            : _desktopSetupChecklist(startScript.parent);
    return 'Voice backend is taking longer than expected to respond.\n'
        'Ensure Voicebox is running (VOICEBOX_API_URL) and retry.\n\n'
        '$setupHint';
  }

  static String _missingBackendFilesMessage() {
    return 'Voice backend files were not found in this app build.\n'
        'Expected to find `voice-backend/start.py` next to the app.';
  }

  static String _desktopSetupChecklist(Directory backendDir) {
    if (Platform.isIOS) {
      return 'Start the MongoBox voice backend on your computer and keep Voicebox running.';
    }

    final hasVenv = _hasVirtualEnv(backendDir);
    final ffmpegInstalled = _commandExists('ffmpeg');
    final activateCommand =
        Platform.isWindows
            ? r'.venv\Scripts\activate'
            : 'source .venv/bin/activate';

    final lines = <String>[
      'To finish voice backend setup:',
      '1. `cd voice-backend`',
      if (!hasVenv) '2. `python -m venv .venv`',
      '3. `$activateCommand`',
      '4. `pip install -r requirements.txt`',
      '5. `python start.py`',
      if (!ffmpegInstalled) '6. Install `ffmpeg` and retry.',
    ];

    return lines.join('\n');
  }

  static bool _hasVirtualEnv(Directory backendDir) {
    if (Platform.isWindows) {
      return File(
        '${backendDir.path}\\.venv\\Scripts\\python.exe',
      ).existsSync();
    }

    return File('${backendDir.path}/.venv/bin/python').existsSync() ||
        File('${backendDir.path}/.venv/bin/python3').existsSync();
  }

  static bool _commandExists(String executable) {
    try {
      return executable.trim().isNotEmpty &&
          Process.runSync(Platform.isWindows ? 'where' : 'which', [
                executable,
              ]).exitCode ==
              0;
    } catch (_) {
      return false;
    }
  }
}
