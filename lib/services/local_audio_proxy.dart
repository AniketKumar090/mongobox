import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// A minimal on-device HTTP proxy that tunnels YouTube stream URLs for AVPlayer.
///
/// Key requirements met in this version:
///   1. Concurrent requests — just_audio / AVPlayer fires multiple simultaneous
///      range requests. Each is handled in its own unawaited Future so they
///      don't queue behind each other (previous version awaited each handler
///      serially, causing timeouts → (-1) unknown error on audio-only streams).
///   2. HEAD support — just_audio probes streams with HEAD before GET. We
///      forward the method correctly so the CDN responds with headers only.
///   3. Persistent HttpClient — one shared client with keep-alive so
///      concurrent requests reuse TCP connections to googlevideo.com.
///   4. Content-Type sniffing fix — always set Content-Type to audio/mp4
///      for mp4 streams when the CDN omits it, so AVPlayer doesn't reject
///      the stream as unknown media.
class LocalAudioProxy {
  LocalAudioProxy._();
  static final LocalAudioProxy instance = LocalAudioProxy._();

  HttpServer? _server;
  HttpClient? _httpClient;

  final Map<String, String> _urlMap = {}; // id → real URL
  int _idCounter = 0;

  int get port => _server?.port ?? 0;
  bool get isRunning => _server != null;

  static const String _androidUserAgent =
      'com.google.android.youtube/19.09.37 (Linux; U; Android 11) gzip';

  /// Start the proxy server on a random available port.
  Future<void> start() async {
    if (_server != null) return;
    if (kIsWeb) return;

    _httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 30)
      ..maxConnectionsPerHost = 6; // allow concurrent range requests

    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      debugPrint('[AudioProxy] Listening on port ${_server!.port}');
      _serveRequests();
    } catch (e) {
      debugPrint('[AudioProxy] Failed to start: $e');
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _httpClient?.close(force: true);
    _httpClient = null;
    _urlMap.clear();
    _idCounter = 0;
  }

  /// Register a real YouTube stream URL and return a localhost URL for AVPlayer.
  String proxyUrl(String realUrl) {
    if (_server == null || kIsWeb) return realUrl;

    for (final entry in _urlMap.entries) {
      if (entry.value == realUrl) {
        return 'http://127.0.0.1:$port/stream?id=${entry.key}';
      }
    }

    final id = (_idCounter++).toString();
    _urlMap[id] = realUrl;
    return 'http://127.0.0.1:$port/stream?id=$id';
  }

  void _serveRequests() {
    _server!.listen(
      (request) {
        // Handle each request concurrently — do NOT await here.
        // Awaiting would serialize all requests, causing just_audio's parallel
        // range probes to time out → (-1) unknown error.
        _handleRequest(request).catchError((e) {
          debugPrint('[AudioProxy] Request error: $e');
          try {
            request.response.statusCode = HttpStatus.internalServerError;
            request.response.close();
          } catch (_) {}
        });
      },
      onError: (e) => debugPrint('[AudioProxy] Server error: $e'),
    );
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final id = request.uri.queryParameters['id'];
    final realUrl = id != null ? _urlMap[id] : null;

    if (realUrl == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final method = request.method.toUpperCase();
    debugPrint('[AudioProxy] $method id=$id '
        '${request.headers.value(HttpHeaders.rangeHeader) ?? ""}');

    final client = _httpClient;
    if (client == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }

    try {
      final uri = Uri.parse(realUrl);

      // Open request with the correct method (HEAD or GET).
      final HttpClientRequest proxyReq;
      if (method == 'HEAD') {
        proxyReq = await client.headUrl(uri);
      } else {
        proxyReq = await client.getUrl(uri);
      }

      // Spoof Android User-Agent — the CDN validates this against the
      // c=ANDROID token embedded in the signed URL.
      proxyReq.headers
        ..set(HttpHeaders.userAgentHeader, _androidUserAgent)
        // Prevent HttpClient from automatically decompressing gzip — we want
        // to stream raw bytes to AVPlayer unchanged.
        ..set(HttpHeaders.acceptEncodingHeader, 'identity');

      // Forward Range so seeking works (AVPlayer uses byte-range requests).
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        proxyReq.headers.set(HttpHeaders.rangeHeader, range);
      }

      final proxyResp = await proxyReq.close();

      // ── Build response ───────────────────────────────────────────────────
      request.response.statusCode = proxyResp.statusCode;

      // Always declare that we support range requests so AVPlayer enables
      // seeking immediately without a preflight round-trip.
      request.response.headers
          .set(HttpHeaders.acceptRangesHeader, 'bytes');

      // Forward essential headers.
      _copyHeader(proxyResp, request.response, HttpHeaders.contentLengthHeader);
      _copyHeader(proxyResp, request.response, HttpHeaders.contentRangeHeader);

      // Content-Type: prefer the CDN's value; fall back to audio/mp4.
      final ct = proxyResp.headers.value(HttpHeaders.contentTypeHeader);
      request.response.headers.set(
        HttpHeaders.contentTypeHeader,
        (ct != null && ct.isNotEmpty) ? ct : 'audio/mp4',
      );

      if (method == 'HEAD') {
        await request.response.close();
        return;
      }

      // Stream response bytes directly to AVPlayer.
      await proxyResp.pipe(request.response);
    } on HttpException catch (e) {
      debugPrint('[AudioProxy] HttpException for id=$id: $e');
      rethrow;
    } on SocketException catch (e) {
      debugPrint('[AudioProxy] SocketException for id=$id: $e');
      rethrow;
    }
  }

  void _copyHeader(
    HttpClientResponse from,
    HttpResponse to,
    String header,
  ) {
    final value = from.headers.value(header);
    if (value != null) {
      try {
        to.headers.set(header, value);
      } catch (_) {}
    }
  }
}