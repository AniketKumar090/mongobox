/// Response from /clone endpoint including voice quality metadata
class VoiceQualityResponse {
  /// Base64-encoded WAV audio data
  final String audioBase64;

  /// Quality score (0-100)
  final double qualityScore;

  /// Quality grade: PASS | WARN | FAIL | UNKNOWN | ERROR
  final String qualityGrade;

  /// Which voice was used: "user" | "synthetic" | "groq"
  final String voiceSource;

  /// Whether fallback voice was used
  final bool usedFallback;

  /// Quality metrics (duration_s, rms_energy, snr_db, etc.)
  final Map<String, dynamic> metrics;

  /// Actionable tips for improving quality
  final List<String> tips;

  VoiceQualityResponse({
    required this.audioBase64,
    required this.qualityScore,
    required this.qualityGrade,
    required this.voiceSource,
    required this.usedFallback,
    required this.metrics,
    required this.tips,
  });

  /// Parse from /clone endpoint JSON response
  factory VoiceQualityResponse.fromJson(Map<String, dynamic> json) {
    return VoiceQualityResponse(
      audioBase64: json['audio_base64'] as String? ?? '',
      qualityScore: (json['quality_score'] as num?)?.toDouble() ?? 100.0,
      qualityGrade: json['quality_grade'] as String? ?? 'UNKNOWN',
      voiceSource: json['voice_source'] as String? ?? 'user',
      usedFallback: json['used_fallback'] as bool? ?? false,
      metrics: json['metrics'] as Map<String, dynamic>? ?? {},
      tips: List<String>.from(json['tips'] as List<dynamic>? ?? []),
    );
  }

  /// Get quality badge text
  String get qualityBadge {
    if (usedFallback) return 'Fallback Used';
    switch (qualityGrade) {
      case 'PASS':
        return qualityScore >= 80 ? 'Excellent' : 'Good';
      case 'WARN':
        return 'Warning';
      case 'FAIL':
        return 'Poor';
      default:
        return 'Unknown';
    }
  }

  /// Get quality badge color (0xAARRGGBB)
  int get qualityBadgeColor {
    if (usedFallback) return 0xFFFFA500; // Orange
    switch (qualityGrade) {
      case 'PASS':
        return qualityScore >= 80 ? 0xFF4CAF50 : 0xFF8BC34A; // Green or Light Green
      case 'WARN':
        return 0xFFFFC107; // Amber
      case 'FAIL':
        return 0xFFF44336; // Red
      default:
        return 0xFF9E9E9E; // Gray
    }
  }

  /// Whether user voice was acceptable
  bool get userVoiceAcceptable => qualityGrade == 'PASS' || qualityGrade == 'WARN';
}
