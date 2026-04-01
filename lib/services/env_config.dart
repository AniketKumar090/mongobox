import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter/services.dart';

class EnvConfig {
  static bool _initialized = false;
  static const MethodChannel _voiceBackendLauncherChannel = MethodChannel(
    'com.example.mongobox/voice_backend_launcher',
  );

  static String _clean(String? value) {
    var v = (value ?? '').trim();
    if (v.length >= 2) {
      final first = v[0];
      final last = v[v.length - 1];
      if ((first == '"' && last == '"') || (first == '\'' && last == '\'')) {
        v = v.substring(1, v.length - 1).trim();
      }
    }
    return v;
  }

  static Future<void> load() async {
    if (_initialized) return;
    try {
      await dotenv.load(fileName: '.env');
      _initialized = true;
      print('✅ .env file loaded successfully');
    } catch (e) {
      print('⚠️  .env file not found or could not be loaded: $e');
      // Continue anyway - we'll try environment variables or fallback
      _initialized = true;
    }
  }

  static String get youtubeApiKey {
    // Try .env file first
    try {
      final envFileKey = dotenv.env['YOUTUBE_API_KEY'];
      if (envFileKey != null && envFileKey.isNotEmpty) {
        return envFileKey;
      }
    } catch (e) {
      print('⚠️  Error reading from .env: $e');
    }

    // Try environment variables (for GitHub Actions)
    final envVarKey = const String.fromEnvironment('YOUTUBE_API_KEY');
    if (envVarKey.isNotEmpty) {
      return envVarKey;
    }

    // Fallback (for build compatibility)
    throw Exception(
      'YOUTUBE_API_KEY not found. '
      'Set in .env file locally or as YOUTUBE_API_KEY environment variable',
    );
  }

  static String get anthropicApiKey {
    // Try .env file first
    try {
      final envFileKey = _clean(dotenv.env['ANTHROPIC_API_KEY']);
      if (envFileKey.isNotEmpty) {
        return envFileKey;
      }
    } catch (e) {
      print('⚠️  Error reading ANTHROPIC_API_KEY from .env: $e');
    }

    // Try compile-time environment (e.g. `--dart-define=ANTHROPIC_API_KEY=...`)
    final envVarKey = _clean(const String.fromEnvironment('ANTHROPIC_API_KEY'));
    if (envVarKey.isNotEmpty) {
      return envVarKey;
    }

    throw Exception(
      'ANTHROPIC_API_KEY not found. '
      'Set in .env locally or pass via --dart-define=ANTHROPIC_API_KEY=...',
    );
  }

  /// Optional. Enables Genius API as a parallel lyric search alongside LRCLIB.
  /// Create a client at https://genius.com/api-clients — use the access token (not secret).
  static String get geniusAccessToken {
    try {
      final envFileKey = _clean(dotenv.env['GENIUS_ACCESS_TOKEN']);
      if (envFileKey.isNotEmpty) {
        return envFileKey;
      }
    } catch (e) {
      print('⚠️  Error reading GENIUS_ACCESS_TOKEN from .env: $e');
    }

    final envVarKey = _clean(
      const String.fromEnvironment('GENIUS_ACCESS_TOKEN'),
    );
    if (envVarKey.isNotEmpty) {
      return envVarKey;
    }

    return '';
  }

  static String get grokApiKey {
    // Try .env file first
    try {
      final envFileKey = _clean(dotenv.env['GROQ_API_KEY']);
      if (envFileKey.isNotEmpty) {
        return envFileKey;
      }
    } catch (e) {
      print('⚠️  Error reading GROQ_API_KEY from .env: $e');
    }

    // Try compile-time environment (e.g. `--dart-define=GROQ_API_KEY=...`)
    final envVarKey = _clean(const String.fromEnvironment('GROQ_API_KEY'));
    if (envVarKey.isNotEmpty) {
      return envVarKey;
    }

    // Groq is optional - return empty string if not configured
    print(
      '⚠️  Grok API key not configured. Grok search refinement will be skipped.',
    );
    return '';
  }

  static String get jamendoClientId {
    // Try .env file first
    try {
      final envFileKey = _clean(dotenv.env['JAMENDO_CLIENT_ID']);
      if (envFileKey.isNotEmpty) {
        return envFileKey;
      }
    } catch (e) {
      print('⚠️  Error reading JAMENDO_CLIENT_ID from .env: $e');
    }

    // Try compile-time environment (e.g. `--dart-define=JAMENDO_CLIENT_ID=...`)
    final envVarKey = _clean(const String.fromEnvironment('JAMENDO_CLIENT_ID'));
    if (envVarKey.isNotEmpty) {
      return envVarKey;
    }

    // Jamendo is optional - return empty string if not configured.
    print(
      '⚠️  Jamendo client id not configured. Background audio search will be disabled.',
    );
    return '';
  }

  static String get soundcloudClientId {
    try {
      final envFileKey = _clean(dotenv.env['SOUNDCLOUD_CLIENT_ID']);
      if (envFileKey.isNotEmpty) return envFileKey;
    } catch (e) {
      print('⚠️  Error reading SOUNDCLOUD_CLIENT_ID from .env: $e');
    }

    final envVarKey = _clean(
      const String.fromEnvironment('SOUNDCLOUD_CLIENT_ID'),
    );
    if (envVarKey.isNotEmpty) return envVarKey;

    print('⚠️  SoundCloud client id not configured.');
    return '';
  }

  static String get soundcloudClientSecret {
    try {
      final envFileKey = _clean(dotenv.env['SOUNDCLOUD_CLIENT_SECRET']);
      if (envFileKey.isNotEmpty) return envFileKey;
    } catch (e) {
      print('⚠️  Error reading SOUNDCLOUD_CLIENT_SECRET from .env: $e');
    }

    final envVarKey = _clean(
      const String.fromEnvironment('SOUNDCLOUD_CLIENT_SECRET'),
    );
    if (envVarKey.isNotEmpty) return envVarKey;

    print('⚠️  SoundCloud client secret not configured.');
    return '';
  }

  static String get voiceBackendUrl {
    try {
      final envFileValue = _clean(dotenv.env['VOICE_BACKEND_URL']);
      if (envFileValue.isNotEmpty) {
        return envFileValue.replaceFirst(RegExp(r'/+$'), '');
      }
    } catch (e) {
      print('⚠️  Error reading VOICE_BACKEND_URL from .env: $e');
    }

    final envVarValue = _clean(
      const String.fromEnvironment('VOICE_BACKEND_URL'),
    );
    if (envVarValue.isNotEmpty) {
      return envVarValue.replaceFirst(RegExp(r'/+$'), '');
    }

    print(
      '⚠️  Voice backend URL not configured. Falling back to '
      'http://127.0.0.1:8000 for local simulator testing.',
    );
    return 'http://127.0.0.1:8000';
  }

  static String get voiceBackendDeviceUrl {
    try {
      final envFileValue = _clean(dotenv.env['VOICE_BACKEND_DEVICE_URL']);
      if (envFileValue.isNotEmpty) {
        return envFileValue.replaceFirst(RegExp(r'/+$'), '');
      }
    } catch (e) {
      print('⚠️  Error reading VOICE_BACKEND_DEVICE_URL from .env: $e');
    }

    final envVarValue = _clean(
      const String.fromEnvironment('VOICE_BACKEND_DEVICE_URL'),
    );
    if (envVarValue.isNotEmpty) {
      return envVarValue.replaceFirst(RegExp(r'/+$'), '');
    }

    try {
      final legacyEnvFileValue = _clean(dotenv.env['VOICE_BACKEND_LAN_URL']);
      if (legacyEnvFileValue.isNotEmpty) {
        return legacyEnvFileValue.replaceFirst(RegExp(r'/+$'), '');
      }
    } catch (_) {
      // Ignore legacy env read failures.
    }

    final legacyEnvVarValue = _clean(
      const String.fromEnvironment('VOICE_BACKEND_LAN_URL'),
    );
    if (legacyEnvVarValue.isNotEmpty) {
      return legacyEnvVarValue.replaceFirst(RegExp(r'/+$'), '');
    }

    return '';
  }

  static Future<String> resolveVoiceBackendUrl() async {
    final configured = voiceBackendUrl;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return configured;
    }

    final uri = Uri.tryParse(configured);
    const localHosts = {'127.0.0.1', 'localhost', '::1'};
    if (uri == null || !localHosts.contains(uri.host)) {
      return configured;
    }

    if (await _isIosSimulator()) {
      return configured;
    }

    final deviceUrl = voiceBackendDeviceUrl;
    if (deviceUrl.isNotEmpty) {
      return deviceUrl;
    }

    return configured;
  }

  static Future<bool> isPhysicalIosDeviceUsingLocalBackend() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return false;
    }

    final uri = Uri.tryParse(voiceBackendUrl);
    const localHosts = {'127.0.0.1', 'localhost', '::1'};
    if (uri == null || !localHosts.contains(uri.host)) {
      return false;
    }

    return !(await _isIosSimulator());
  }

  static String voiceBackendPhysicalDeviceHelp() {
    return 'Physical iPhone cannot reach 127.0.0.1. '
        'Set VOICE_BACKEND_DEVICE_URL to your Mac LAN IP '
        '(for example http://192.168.1.42:8000) and start the backend with: '
        'cd voice-backend && python start.py --host 0.0.0.0';
  }

  static Future<bool> _isIosSimulator() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return false;
    }

    try {
      final value = await _voiceBackendLauncherChannel.invokeMethod<bool>(
        'isSimulator',
      );
      return value ?? false;
    } catch (_) {
      return false;
    }
  }

  static String get invidiousBaseUrl {
    try {
      final envFileValue = _clean(dotenv.env['INVIDIOUS_BASE_URL']);
      if (envFileValue.isNotEmpty) {
        return envFileValue.replaceFirst(RegExp(r'/+$'), '');
      }
    } catch (e) {
      print('⚠️  Error reading INVIDIOUS_BASE_URL from .env: $e');
    }

    final envVarValue = _clean(
      const String.fromEnvironment('INVIDIOUS_BASE_URL'),
    );
    if (envVarValue.isNotEmpty) {
      return envVarValue.replaceFirst(RegExp(r'/+$'), '');
    }

    return '';
  }
}
