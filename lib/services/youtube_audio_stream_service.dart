import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'local_audio_proxy.dart';
import 'lyric_audio_playback.dart';

/// Resolves playable audio stream URLs for a YouTube video ID.
///
/// Fix log (2025-Q2 v3 — proxy approach):
///   Problem recap:
///     - Android client reliably resolves stream manifests but produces
///       `c=ANDROID`-signed URLs. AVPlayer rejects these with (-11828).
///     - iOS/mweb/safari/tv clients all fail bot-checks (403 / "Sign in to
///       confirm you're not a bot") for bot-detection-sensitive videos.
///     - URL rewriting (c=ANDROID→c=IOS) invalidates the sig= signature.
///
///   Solution:
///     Use the android client to resolve URLs (it works), then wrap each URL
///     in [LocalAudioProxy] which fetches the real stream server-side with a
///     spoofed Android User-Agent and pipes bytes back to AVPlayer via
///     localhost. AVPlayer talks to 127.0.0.1 and never sees the signed URL;
///     the proxy satisfies the CDN by presenting the correct client headers.
///
///   On Android the proxy is skipped entirely — ExoPlayer handles signed URLs
///   natively.
class YouTubeAudioStreamService {
  YouTubeAudioStreamService._();

  static final YouTubeAudioStreamService instance =
      YouTubeAudioStreamService._();

  YoutubeExplode _yt = YoutubeExplode();
  int _requestCount = 0;
  static const int _ytRefreshAfterRequests = 15;

  final Map<
    String,
    ({List<BackgroundStreamSource> sources, DateTime fetchedAt})
  > _cache = {};

  static const Duration _cacheTtl = Duration(minutes: 18);

  bool get _isApple =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  // ── Public API ────────────────────────────────────────────────────────────

  /// Call once at app startup (e.g. in main() after WidgetsFlutterBinding).
  Future<void> init() async {
    if (_isApple) {
      await LocalAudioProxy.instance.start();
      debugPrint(
        '[YouTubeAudio] Local proxy started on port '
        '${LocalAudioProxy.instance.port}',
      );
    }
  }

  Future<List<BackgroundStreamSource>> getPlayableAudioSources(
    String videoId,
  ) async {
    final id = videoId.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(videoId, 'videoId', 'Must not be empty');
    }

    // Ensure proxy is running (idempotent).
    if (_isApple && !LocalAudioProxy.instance.isRunning) {
      await LocalAudioProxy.instance.start();
    }

    final cached = _cache[id];
    if (cached != null) {
      final age = DateTime.now().difference(cached.fetchedAt);
      if (age <= _cacheTtl && cached.sources.isNotEmpty) {
        debugPrint('[YouTubeAudio] Cache hit for $id (age: ${age.inMinutes}m)');
        return cached.sources;
      }
      _cache.remove(id);
    }

    _requestCount++;
    if (_requestCount >= _ytRefreshAfterRequests) {
      _recycleYtClient();
    }

    try {
      final sources = await _resolveWithRetry(id);
      if (sources.isEmpty) {
        throw YoutubeExplodeException(
          'No playable YouTube audio sources were available for this video.',
        );
      }
      _cache[id] = (sources: sources, fetchedAt: DateTime.now());
      debugPrint('[YouTubeAudio] Resolved ${sources.length} source(s) for $id');
      return sources;
    } catch (e) {
      debugPrint('[YouTubeAudio] All strategies failed for $id: $e');
      rethrow;
    }
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  void _recycleYtClient() {
    try {
      _yt.close();
    } catch (_) {}
    _yt = YoutubeExplode();
    _requestCount = 0;
    debugPrint('[YouTubeAudio] Recycled YoutubeExplode client');
  }

  /// Wrap a real stream URL in the local proxy when on iOS/macOS.
  /// On Android, return the URL unchanged — ExoPlayer handles it natively.
  BackgroundStreamSource _makeSource(AudioStreamInfo stream) {
    final url = stream.url.toString();
    if (_isApple) {
      final proxied = LocalAudioProxy.instance.proxyUrl(url);
      return (url: proxied, headers: null);
    }
    return (url: url, headers: null);
  }

  List<({YoutubeApiClient client, String label, bool watchPage})>
  _clientStrategy() {
    if (_isApple) {
      // On iOS we use the android client because it reliably bypasses bot
      // checks. The local proxy handles the client-token mismatch.
      return [
        (client: YoutubeApiClient.android, label: 'android+wp', watchPage: true),
        (client: YoutubeApiClient.androidVr, label: 'androidVr+wp', watchPage: true),
        // Fallbacks in case android starts failing.
        (client: YoutubeApiClient.ios, label: 'ios+wp', watchPage: true),
        (client: YoutubeApiClient.tv, label: 'tv+wp', watchPage: true),
        (client: YoutubeApiClient.android, label: 'android', watchPage: false),
        (client: YoutubeApiClient.ios, label: 'ios', watchPage: false),
      ];
    } else {
      return [
        (client: YoutubeApiClient.android, label: 'android+wp', watchPage: true),
        (client: YoutubeApiClient.androidVr, label: 'androidVr+wp', watchPage: true),
        (client: YoutubeApiClient.tv, label: 'tv+wp', watchPage: true),
        (client: YoutubeApiClient.mweb, label: 'mweb+wp', watchPage: true),
        (client: YoutubeApiClient.ios, label: 'ios+wp', watchPage: true),
        (client: YoutubeApiClient.android, label: 'android', watchPage: false),
        (client: YoutubeApiClient.tv, label: 'tv', watchPage: false),
        (client: YoutubeApiClient.ios, label: 'ios', watchPage: false),
      ];
    }
  }

  Future<List<BackgroundStreamSource>> _resolveWithRetry(
    String videoId,
  ) async {
    final seen = <String>{};
    final sources = <BackgroundStreamSource>[];

    for (final entry in _clientStrategy()) {
      if (sources.isNotEmpty) break;

      try {
        final manifest = await _yt.videos.streamsClient.getManifest(
          videoId,
          ytClients: [entry.client],
          requireWatchPage: entry.watchPage,
        );

        for (final stream in _rankStreams(manifest)) {
          final source = _makeSource(stream);
          if (!seen.add(source.url)) continue;
          debugPrint(
            '[YouTubeAudio] ✓ ${entry.label}: '
            '${stream.container.name} ${stream.codec.mimeType} '
            '${stream.bitrate.kiloBitsPerSecond.round()}kbps'
            '${_isApple ? " [proxied]" : ""}',
          );
          sources.add(source);
        }

        if (sources.isNotEmpty) {
          debugPrint(
            '[YouTubeAudio] Got ${sources.length} source(s) via ${entry.label}',
          );
        }
      } catch (e) {
        debugPrint('[YouTubeAudio] ✗ ${entry.label}: $e');
      }
    }

    // Last-resort retry after recycling the client.
    if (sources.isEmpty) {
      debugPrint('[YouTubeAudio] All clients failed — recycling and retrying…');
      _recycleYtClient();
      await Future<void>.delayed(const Duration(milliseconds: 600));

      for (final client in [YoutubeApiClient.android, YoutubeApiClient.androidVr]) {
        try {
          final manifest = await _yt.videos.streamsClient.getManifest(
            videoId,
            ytClients: [client],
            requireWatchPage: true,
          );
          for (final stream in _rankStreams(manifest)) {
            final source = _makeSource(stream);
            if (seen.add(source.url)) sources.add(source);
          }
          if (sources.isNotEmpty) break;
        } catch (e) {
          debugPrint('[YouTubeAudio] Last-resort $client failed: $e');
        }
      }
    }

    return sources;
  }

  /// Rank streams.
  ///
  /// iOS (all proxied): mp4 audio-only first (smaller, faster to buffer),
  /// then HLS audio, then mp4 muxed fallback.
  /// WebM excluded — AVPlayer cannot decode Opus even via proxy.
  ///
  /// Android: audio-only first (any codec), then HLS, then muxed.
  List<AudioStreamInfo> _rankStreams(StreamManifest manifest) {
    final ranked = <AudioStreamInfo>[];
    final seen = <String>{};

    void add(AudioStreamInfo s) {
      if (seen.add(s.url.toString())) ranked.add(s);
    }

    final audioOnly = manifest.audioOnly.sortByBitrate().toList();
    final muxed = manifest.muxed.sortByBitrate().toList();
    final hlsAudio = manifest.hls.whereType<HlsAudioStreamInfo>().toList()
      ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
    final hlsMuxed = manifest.hls.whereType<HlsMuxedStreamInfo>().toList()
      ..sort((a, b) => b.bitrate.compareTo(a.bitrate));

    if (_isApple) {
      for (final s in audioOnly.where((s) => s.container == StreamContainer.mp4)) {
        add(s);
      }
      for (final s in hlsAudio) add(s);
      for (final s in muxed.where((s) => s.container == StreamContainer.mp4)) {
        add(s);
      }
      for (final s in hlsMuxed) add(s);
      // WebM/Opus intentionally excluded.
    } else {
      for (final s in audioOnly) add(s);
      for (final s in hlsAudio) add(s);
      for (final s in muxed) add(s);
      for (final s in hlsMuxed) add(s);
    }

    return ranked;
  }

  Future<void> dispose() async {
    if (!kIsWeb) {
      try {
        _yt.close();
      } catch (_) {}
    }
    await LocalAudioProxy.instance.stop();
  }
}