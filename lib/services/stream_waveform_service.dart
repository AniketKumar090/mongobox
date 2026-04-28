import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'lyric_audio_playback.dart';

class StreamWaveformService {
  StreamWaveformService._();

  static final StreamWaveformService instance = StreamWaveformService._();

  static const int _defaultBarCount = 84;
  static const int _sampleChunkCount = 12;
  static const int _sampleChunkBytes = 6144;
  static const Duration _requestTimeout = Duration(seconds: 6);

  final Map<String, List<double>> _cache = {};

  List<double> placeholderBars({
    String seed = 'placeholder',
    int barCount = _defaultBarCount,
  }) => _seededFallback(seed, barCount);

  Future<List<double>> loadWaveform({
    required String trackId,
    required List<BackgroundStreamSource> sources,
    String? fallbackSeed,
    int barCount = _defaultBarCount,
  }) async {
    final cached = _cache[trackId];
    if (cached != null && cached.length == barCount) return cached;

    for (final source in sources) {
      final bars = await _extractBarsFromSource(source, barCount);
      if (bars != null && bars.isNotEmpty) {
        _cache[trackId] = bars;
        return bars;
      }
    }

    final fallback = _seededFallback(fallbackSeed ?? trackId, barCount);
    _cache[trackId] = fallback;
    return fallback;
  }

  Future<List<double>?> _extractBarsFromSource(
    BackgroundStreamSource source,
    int barCount,
  ) async {
    final uri = Uri.tryParse(source.url.trim());
    if (uri == null || !uri.isAbsolute) return null;

    try {
      final probe = await _getBytes(
        uri,
        source.headers,
        range: 'bytes=0-${_sampleChunkBytes - 1}',
      );
      if (probe == null || probe.bodyBytes.isEmpty) return null;

      final contentLength =
          _parseContentRangeLength(probe.headers['content-range']) ??
          int.tryParse(probe.headers['content-length'] ?? '');

      if (contentLength == null || contentLength <= _sampleChunkBytes * 2) {
        return _normalizeBars(_barsFromBytes(probe.bodyBytes, barCount));
      }

      final bars = <double>[];
      final barsPerChunk = (barCount / _sampleChunkCount).ceil();

      for (var i = 0; i < _sampleChunkCount; i++) {
        final sampleFraction =
            _sampleChunkCount == 1 ? 0.5 : i / (_sampleChunkCount - 1);
        final targetOffset = contentLength * (0.03 + (sampleFraction * 0.94));
        final start = math.min(
          math.max(0, targetOffset.floor()),
          math.max(0, contentLength - _sampleChunkBytes),
        );
        final end = math.min(contentLength - 1, start + _sampleChunkBytes - 1);
        final response = await _getBytes(
          uri,
          source.headers,
          range: 'bytes=$start-$end',
        );
        if (response == null || response.bodyBytes.isEmpty) continue;
        bars.addAll(_barsFromBytes(response.bodyBytes, barsPerChunk));
      }

      if (bars.length < barCount ~/ 2) return null;
      return _normalizeBars(bars.take(barCount).toList());
    } catch (_) {
      return null;
    }
  }

  Future<http.Response?> _getBytes(
    Uri uri,
    Map<String, String>? headers, {
    String? range,
  }) async {
    final mergedHeaders = <String, String>{
      if (headers != null) ...headers,
      'accept-encoding': 'identity',
      if (range != null) 'range': range,
    };
    final response = await http
        .get(uri, headers: mergedHeaders)
        .timeout(_requestTimeout);
    if (response.statusCode != 200 && response.statusCode != 206) {
      return null;
    }
    return response;
  }

  int? _parseContentRangeLength(String? contentRange) {
    if (contentRange == null || contentRange.isEmpty) return null;
    final slashIndex = contentRange.lastIndexOf('/');
    if (slashIndex == -1 || slashIndex >= contentRange.length - 1) {
      return null;
    }
    return int.tryParse(contentRange.substring(slashIndex + 1).trim());
  }

  List<double> _barsFromBytes(Uint8List bytes, int barCount) {
    if (bytes.isEmpty || barCount <= 0) return const [];
    final bars = <double>[];

    for (var i = 0; i < barCount; i++) {
      final start = (i * bytes.length / barCount).floor();
      final end = math.max(
        start + 1,
        ((i + 1) * bytes.length / barCount).floor(),
      );
      if (start >= bytes.length) break;
      final clampedEnd = math.min(end, bytes.length);

      var sum = 0.0;
      for (var j = start; j < clampedEnd; j++) {
        sum += bytes[j];
      }
      final sampleCount = clampedEnd - start;
      final mean = sampleCount == 0 ? 0.0 : sum / sampleCount;

      var variance = 0.0;
      var edgeEnergy = 0.0;
      for (var j = start; j < clampedEnd; j++) {
        final centered = bytes[j] - mean;
        variance += centered * centered;
        if (j > start) {
          edgeEnergy += (bytes[j] - bytes[j - 1]).abs();
        }
      }

      final deviation =
          sampleCount == 0 ? 0.0 : math.sqrt(variance / sampleCount);
      final movement = sampleCount <= 1 ? 0.0 : edgeEnergy / (sampleCount - 1);
      bars.add(deviation + (movement * 0.6));
    }

    return bars;
  }

  List<double> _normalizeBars(List<double> rawBars) {
    if (rawBars.isEmpty) return const [];

    final minValue = rawBars.reduce(math.min);
    final maxValue = rawBars.reduce(math.max);
    if ((maxValue - minValue).abs() < 0.0001) {
      return _seededFallback(
        'flat-${rawBars.length}-${maxValue.toStringAsFixed(4)}',
        rawBars.length,
      );
    }

    final normalized =
        rawBars
            .map((value) => ((value - minValue) / (maxValue - minValue)))
            .map((value) => 0.14 + (math.pow(value, 0.82) * 0.86))
            .cast<double>()
            .toList();

    return _smoothBars(normalized);
  }

  List<double> _smoothBars(List<double> bars) {
    if (bars.length < 3) return bars;
    final smoothed = List<double>.filled(bars.length, 0);
    for (var i = 0; i < bars.length; i++) {
      final previous = i == 0 ? bars[i] : bars[i - 1];
      final current = bars[i];
      final next = i == bars.length - 1 ? bars[i] : bars[i + 1];
      smoothed[i] = (previous * 0.22) + (current * 0.56) + (next * 0.22);
    }
    return smoothed;
  }

  List<double> _seededFallback(String seed, int barCount) {
    final seedValue = seed.codeUnits.fold<int>(0, (sum, unit) {
      return (sum * 31 + unit) & 0x7fffffff;
    });
    final random = math.Random(seedValue);
    final bars = List<double>.generate(barCount, (index) {
      final sweep = math.sin((index / math.max(1, barCount - 1)) * math.pi);
      final ripple = 0.5 + (0.5 * math.sin(index * 0.45 + random.nextDouble()));
      final noise = 0.3 + (random.nextDouble() * 0.7);
      final value = (sweep * 0.38) + (ripple * 0.32) + (noise * 0.30);
      return value.clamp(0.14, 1.0);
    });
    return _smoothBars(bars);
  }
}
