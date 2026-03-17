import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  bool _isSpeaking = false;

  bool get isSpeaking => _isSpeaking;

  Future<void> init({VoidCallback? onStateChanged}) async {
    if (_initialized) return;
    _initialized = true;

    try {
      await _tts.awaitSpeakCompletion(true);
    } catch (_) {
      // Some platforms/implementations may not support this; best effort.
    }

    _tts.setStartHandler(() {
      _isSpeaking = true;
      onStateChanged?.call();
    });
    _tts.setCompletionHandler(() {
      _isSpeaking = false;
      onStateChanged?.call();
    });
    _tts.setCancelHandler(() {
      _isSpeaking = false;
      onStateChanged?.call();
    });
    _tts.setErrorHandler((message) {
      _isSpeaking = false;
      onStateChanged?.call();
      debugPrint('TTS error: $message');
    });

    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS)) {
      try {
        await _tts.setSharedInstance(true);
        await _tts.setIosAudioCategory(
          IosTextToSpeechAudioCategory.playback,
          [
            IosTextToSpeechAudioCategoryOptions.mixWithOthers,
            IosTextToSpeechAudioCategoryOptions.defaultToSpeaker,
            IosTextToSpeechAudioCategoryOptions.allowBluetooth,
            IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
          ],
          IosTextToSpeechAudioMode.voicePrompt,
        );
      } catch (e) {
        debugPrint('TTS iOS audio config failed: $e');
      }
    }

    final locale = WidgetsBinding.instance.platformDispatcher.locale;
    final languageTag = (locale.countryCode?.isNotEmpty ?? false)
        ? '${locale.languageCode}-${locale.countryCode}'
        : locale.languageCode;

    try {
      await _tts.setLanguage(languageTag);
    } catch (_) {
      // If the locale voice isn't available, the platform will pick a default.
    }

    // Best-effort defaults.
    try {
      await _tts.setSpeechRate(0.45);
    } catch (_) {}
    try {
      await _tts.setPitch(1.0);
    } catch (_) {}
    try {
      await _tts.setVolume(1.0);
    } catch (_) {}
  }

  Future<void> speak(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await stop();
    await _tts.speak(trimmed);
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }

  void dispose() {
    stop();
  }
}

