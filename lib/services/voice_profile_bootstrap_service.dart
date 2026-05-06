import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'env_config.dart';

class VoiceProfileBootstrapResult {
  const VoiceProfileBootstrapResult({
    required this.profileId,
    required this.profileName,
    required this.language,
    required this.engine,
    required this.referenceText,
  });

  final String profileId;
  final String profileName;
  final String language;
  final String engine;
  final String referenceText;
}

class VoiceProfileBootstrapService {
  VoiceProfileBootstrapService({http.Client? client})
    : _client = client ?? http.Client();

  static const _prefsProfileIdKey = 'mongobox_voicebox_profile_id';
  static const _prefsProfileNameKey = 'mongobox_voicebox_profile_name';

  final http.Client _client;

  Future<VoiceProfileBootstrapResult> bootstrapProfile({
    required String voiceSamplePath,
    required String language,
  }) async {
    if (await EnvConfig.isPhysicalIosDeviceUsingLocalBackend()) {
      throw Exception(EnvConfig.voiceBackendPhysicalDeviceHelp());
    }

    final backendUrl = await EnvConfig.resolveVoiceBackendUrl();
    final prefs = await SharedPreferences.getInstance();
    final storedProfileId = (prefs.getString(_prefsProfileIdKey) ?? '').trim();

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$backendUrl/voicebox/profile/bootstrap'),
    );
    request.fields['language'] = language.trim();
    if (storedProfileId.isNotEmpty) {
      request.fields['profile_id'] = storedProfileId;
    }
    request.files.add(
      await http.MultipartFile.fromPath('voice_sample', voiceSamplePath),
    );

    late final http.StreamedResponse streamedResponse;
    try {
      streamedResponse = await _client
          .send(request)
          .timeout(const Duration(minutes: 3));
    } on SocketException {
      final physicalIosLoopback =
          await EnvConfig.isPhysicalIosDeviceUsingLocalBackend();
      throw Exception(
        physicalIosLoopback
            ? EnvConfig.voiceBackendPhysicalDeviceHelp()
            : 'Could not reach the voice backend at $backendUrl.',
      );
    } on TimeoutException {
      throw Exception('Voice profile setup timed out. Please try again.');
    }

    final response = await http.Response.fromStream(streamedResponse);
    if (response.statusCode != 200) {
      final detail = response.body.trim();
      throw Exception(
        detail.isEmpty
            ? 'Voice profile setup failed with status ${response.statusCode}.'
            : 'Voice profile setup failed: $detail',
      );
    }

    final decoded = json.decode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Voice profile setup returned an unexpected response.');
    }

    final profileId = (decoded['profile_id'] as String? ?? '').trim();
    final profileName = (decoded['profile_name'] as String? ?? '').trim();
    final resolvedLanguage = (decoded['language'] as String? ?? '').trim();
    final engine = (decoded['engine'] as String? ?? '').trim();
    final referenceText = (decoded['reference_text'] as String? ?? '').trim();

    if (profileId.isEmpty) {
      throw Exception('Voice profile setup completed without a profile id.');
    }

    await prefs.setString(_prefsProfileIdKey, profileId);
    if (profileName.isNotEmpty) {
      await prefs.setString(_prefsProfileNameKey, profileName);
    }

    return VoiceProfileBootstrapResult(
      profileId: profileId,
      profileName: profileName,
      language: resolvedLanguage,
      engine: engine,
      referenceText: referenceText,
    );
  }

  void dispose() {
    _client.close();
  }
}
