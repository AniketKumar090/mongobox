import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter/services.dart';

class EnvConfig {
  static bool _initialized = false;
  static const MethodChannel _voiceBackendLauncherChannel = MethodChannel(
    'com.example.mongobox/voice_backend_launcher',
  );
  static const _defaultVoiceBackendUrl = 'http://127.0.0.1:8000';
  static bool _didReadVoiceBackendUrl = false;
  static bool _didReadVoiceBackendDeviceUrl = false;
  static bool _didLogVoiceBackendUrlReadError = false;
  static bool _didLogVoiceBackendDeviceUrlReadError = false;
  static bool _didLogVoiceBackendFallback = false;
  static String _cachedVoiceBackendUrl = '';
  static String _cachedVoiceBackendDeviceUrl = '';

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
      print('✅ .env file loaded successfully');
    } catch (e) {
      print('⚠️  .env file not found or could not be loaded: $e');
      // Continue anyway - we'll try environment variables or fallback
    } finally {
      _resetVoiceBackendCache();
      _initialized = true;
    }
  }

  static void _resetVoiceBackendCache() {
    _didReadVoiceBackendUrl = false;
    _didReadVoiceBackendDeviceUrl = false;
    _didLogVoiceBackendUrlReadError = false;
    _didLogVoiceBackendDeviceUrlReadError = false;
    _didLogVoiceBackendFallback = false;
    _cachedVoiceBackendUrl = '';
    _cachedVoiceBackendDeviceUrl = '';
  }

  static String _normalizeUrl(String value) {
    return value.replaceFirst(RegExp(r'/+$'), '');
  }

  static String _readVoiceBackendUrl() {
    if (_didReadVoiceBackendUrl) return _cachedVoiceBackendUrl;

    var resolved = '';
    try {
      final envFileValue = _clean(dotenv.env['VOICE_BACKEND_URL']);
      if (envFileValue.isNotEmpty) {
        resolved = _normalizeUrl(envFileValue);
      }
    } catch (e) {
      if (!_didLogVoiceBackendUrlReadError) {
        print('⚠️  Error reading VOICE_BACKEND_URL from .env: $e');
        _didLogVoiceBackendUrlReadError = true;
      }
    }

    if (resolved.isEmpty) {
      final envVarValue = _clean(
        const String.fromEnvironment('VOICE_BACKEND_URL'),
      );
      if (envVarValue.isNotEmpty) {
        resolved = _normalizeUrl(envVarValue);
      }
    }

    _didReadVoiceBackendUrl = true;
    _cachedVoiceBackendUrl = resolved;
    return resolved;
  }

  static String _readVoiceBackendDeviceUrl() {
    if (_didReadVoiceBackendDeviceUrl) return _cachedVoiceBackendDeviceUrl;

    var resolved = '';
    try {
      final envFileValue = _clean(dotenv.env['VOICE_BACKEND_DEVICE_URL']);
      if (envFileValue.isNotEmpty) {
        resolved = _normalizeUrl(envFileValue);
      }
    } catch (e) {
      if (!_didLogVoiceBackendDeviceUrlReadError) {
        print('⚠️  Error reading VOICE_BACKEND_DEVICE_URL from .env: $e');
        _didLogVoiceBackendDeviceUrlReadError = true;
      }
    }

    if (resolved.isEmpty) {
      final envVarValue = _clean(
        const String.fromEnvironment('VOICE_BACKEND_DEVICE_URL'),
      );
      if (envVarValue.isNotEmpty) {
        resolved = _normalizeUrl(envVarValue);
      }
    }

    if (resolved.isEmpty) {
      try {
        final legacyEnvFileValue = _clean(dotenv.env['VOICE_BACKEND_LAN_URL']);
        if (legacyEnvFileValue.isNotEmpty) {
          resolved = _normalizeUrl(legacyEnvFileValue);
        }
      } catch (_) {
        // Ignore legacy env read failures.
      }
    }

    if (resolved.isEmpty) {
      final legacyEnvVarValue = _clean(
        const String.fromEnvironment('VOICE_BACKEND_LAN_URL'),
      );
      if (legacyEnvVarValue.isNotEmpty) {
        resolved = _normalizeUrl(legacyEnvVarValue);
      }
    }

    _didReadVoiceBackendDeviceUrl = true;
    _cachedVoiceBackendDeviceUrl = resolved;
    return resolved;
  }

  static String _voiceBackendFallbackUrl() {
    if (!_didLogVoiceBackendFallback) {
      print(
        '⚠️  Voice backend URL not configured. Falling back to '
        '$_defaultVoiceBackendUrl for local simulator testing.',
      );
      _didLogVoiceBackendFallback = true;
    }
    return _defaultVoiceBackendUrl;
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
    final configured = _readVoiceBackendUrl();
    return configured.isNotEmpty ? configured : _voiceBackendFallbackUrl();
  }

  static String get voiceBackendDeviceUrl {
    return _readVoiceBackendDeviceUrl();
  }

  static Future<String> resolveVoiceBackendUrl() async {
    final configured = _readVoiceBackendUrl();
    final baseUrl =
        configured.isNotEmpty ? configured : _defaultVoiceBackendUrl;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return configured.isNotEmpty ? configured : _voiceBackendFallbackUrl();
    }

    final uri = Uri.tryParse(baseUrl);
    const localHosts = {'127.0.0.1', 'localhost', '::1'};
    if (uri == null || !localHosts.contains(uri.host)) {
      return configured.isNotEmpty ? configured : _voiceBackendFallbackUrl();
    }

    if (await _isIosSimulator()) {
      return configured.isNotEmpty ? configured : _voiceBackendFallbackUrl();
    }

    final deviceUrl = _readVoiceBackendDeviceUrl();
    if (deviceUrl.isNotEmpty) {
      return deviceUrl;
    }

    return configured.isNotEmpty ? configured : _voiceBackendFallbackUrl();
  }

  static Future<bool> isPhysicalIosDeviceUsingLocalBackend() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return false;
    }

    final resolvedUrl = await resolveVoiceBackendUrl();
    final uri = Uri.tryParse(resolvedUrl);
    const localHosts = {'127.0.0.1', 'localhost', '::1'};
    if (uri == null || !localHosts.contains(uri.host)) {
      return false;
    }

    return !(await _isIosSimulator());
  }

  static String voiceBackendPhysicalDeviceHelp() {
    return 'Physical iPhone cannot reach 127.0.0.1 on your Mac. '
        'Add VOICE_BACKEND_DEVICE_URL to .env with your Mac LAN IP and port '
        '(run `cd voice-backend && python start.py` — it prints the value). '
        'Keep VOICE_BACKEND_URL=http://127.0.0.1:8000 for the simulator.';
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
