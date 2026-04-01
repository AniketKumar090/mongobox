// lib/screens/join_via_link_screen.dart
// Full-screen camera with glassmorphic overlay for joining parties

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:url_launcher/url_launcher.dart';
import '../constants/colors.dart';
import 'join_party_screen.dart';
import 'lyric_home_screen.dart';

class JoinViaLinkScreen extends StatefulWidget {
  const JoinViaLinkScreen({super.key, this.onBack});

  final VoidCallback? onBack;

  @override
  State<JoinViaLinkScreen> createState() => _JoinViaLinkScreenState();
}

class _JoinViaLinkScreenState extends State<JoinViaLinkScreen> {
  final _linkController = TextEditingController();
  final FocusNode _linkFocusNode = FocusNode();
  bool _opening = false;
  bool _cameraError = false;
  bool _isResolvingLink = false;
  bool _hasProcessedScan = false;
  MobileScannerController? _scannerController;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  void _initCamera() {
    _scannerController = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
      torchEnabled: false,
    );
  }

  @override
  void dispose() {
    _linkController.dispose();
    _linkFocusNode.dispose();
    _scannerController?.dispose();
    super.dispose();
  }

  Future<void> _openLink(String url) async {
    if (_isResolvingLink) return;
    _isResolvingLink = true;
    debugPrint('🔗 Opening link: $url');
    var didNavigate = false;

    final normalizedUrl =
        url.startsWith('http://') || url.startsWith('https://')
            ? url
            : 'https://$url';

    final uri = Uri.tryParse(normalizedUrl);
    if (uri == null) {
      _hasProcessedScan = false;
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Invalid link')));
      }
      _isResolvingLink = false;
      return;
    }

    final partyId = _extractPartyId(url);
    debugPrint('🎪 Extracted partyId: $partyId');

    if (partyId != null && partyId.isNotEmpty) {
      debugPrint('✅ Joining in-app with partyId: $partyId');
      await _scannerController?.stop();
      didNavigate = true;
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder:
                (_) => JoinPartyScreen(onBack: widget.onBack, partyId: partyId),
          ),
        );
      }
      return;
    }

    // Open externally
    if (mounted) {
      setState(() => _opening = true);
    }
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      _hasProcessedScan = false;
      debugPrint('❌ Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (!didNavigate) {
        _isResolvingLink = false;
        if (mounted) {
          setState(() => _opening = false);
        } else {
          _opening = false;
        }
      }
    }
  }

  String? _extractPartyId(String url) {
    final directPartyId = _normalizePartyId(url);
    if (directPartyId != null) {
      return directPartyId;
    }

    try {
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        url = 'https://$url';
      }
      final uri = Uri.parse(url);
      final queryPartyId = _normalizePartyId(uri.queryParameters['partyId']);
      if (queryPartyId != null) {
        return queryPartyId;
      }

      for (final segment in uri.pathSegments.reversed) {
        final segmentPartyId = _normalizePartyId(segment);
        if (segmentPartyId != null) {
          return segmentPartyId;
        }
      }

      return _normalizePartyId(uri.host);
    } catch (e) {
      return null;
    }
  }

  String? _normalizePartyId(String? rawValue) {
    if (rawValue == null) return null;

    var value = rawValue.trim();
    if (value.isEmpty) return null;

    if (value.startsWith('#')) {
      value = value.substring(1);
    }

    if (value.startsWith('party_')) {
      return value;
    }

    if (RegExp(r'^\d+$').hasMatch(value)) {
      return 'party_$value';
    }

    return null;
  }

  void _onLinkSubmitted() {
    final link = _linkController.text.trim();
    if (link.isEmpty) return;
    _openLink(link);
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        extendBody: true,
        extendBodyBehindAppBar: true,
        body: _buildFullScreenCamera(),
      ),
    );
  }

  Widget _buildFullScreenCamera() {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Full-screen camera (ignoring ALL safe areas)
        _cameraError
            ? _buildCameraUnavailable()
            : MobileScanner(
              controller: _scannerController!,
              onDetect: (capture) {
                if (_hasProcessedScan || _isResolvingLink) return;
                final barcodes = capture.barcodes;
                if (barcodes.isEmpty) return;
                final code = barcodes.first.rawValue;
                if (code == null || code.isEmpty) return;
                _hasProcessedScan = true;
                _openLink(code);
              },
              errorBuilder: (context, error) {
                if (!_cameraError) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() => _cameraError = true);
                  });
                }
                return _buildCameraUnavailable();
              },
              fit: BoxFit.cover,
            ),

        // QR Scanner corner brackets (positioned in upper middle)
        const Positioned(
          top: 120,
          left: 0,
          right: 0,
          child: _ScannerCornerOverlay(),
        ),

        // Close button (top left)
        Positioned(
          top: MediaQuery.of(context).padding.top + 12,
          left: 16,
          child: SafeArea(
            top: false,
            bottom: false,
            right: false,
            child: GestureDetector(
              onTap: () {
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => const LyricHomeScreen()),
                );
              },
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.3),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close_rounded,
                  color: Colors.white,
                  size: 24,
                ),
              ),
            ),
          ),
        ),

        // Glassmorphic panel at bottom
        Positioned(left: 0, right: 0, bottom: 0, child: _buildGlassJoinPanel()),
      ],
    );
  }

  Widget _buildCameraUnavailable() {
    return Container(
      color: Colors.black,
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.camera_alt_outlined, size: 64, color: Colors.white38),
            SizedBox(height: 16),
            Text(
              'Camera unavailable',
              style: TextStyle(color: Colors.white54, fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGlassJoinPanel() {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.1),
                Colors.black.withValues(alpha: 0.4),
              ],
            ),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
            border: Border(
              top: BorderSide(
                color: Colors.white.withValues(alpha: 0.2),
                width: 1,
              ),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Handle bar
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Icon
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(60),
                    ),
                    child: const Icon(
                      Icons.qr_code_scanner_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Title
                  const Text(
                    'Join a Party',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Description
                  const Text(
                    'Scan QR code or paste link below',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: Colors.white70,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Link input field
                  _buildLinkInputField(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLinkInputField() {
    return ListenableBuilder(
      listenable: _linkFocusNode,
      builder: (context, _) {
        final hasFocus = _linkFocusNode.hasFocus;
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF8F4EE),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: hasFocus ? AppColors.accent : const Color(0xFFD8D4CC),
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              const SizedBox(width: 14),
              const Icon(
                Icons.link_rounded,
                color: Color(0xFF555555),
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Theme(
                  data: Theme.of(context).copyWith(
                    textSelectionTheme: const TextSelectionThemeData(
                      cursorColor: Colors.black,
                      selectionColor: Color(0x447C5CFF),
                      selectionHandleColor: Colors.black,
                    ),
                  ),
                  child: TextField(
                    controller: _linkController,
                    focusNode: _linkFocusNode,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Colors.black,
                    ),
                    cursorColor: Colors.black,
                    decoration: const InputDecoration(
                      hintText: 'Paste party link or ID',
                      hintStyle: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFFAAAAAA),
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: true,
                      fillColor: Colors.transparent,
                      contentPadding: EdgeInsets.symmetric(vertical: 16),
                    ),
                    onSubmitted: (_) => _onLinkSubmitted(),
                  ),
                ),
              ),
              GestureDetector(
                onTap: _opening ? null : _onLinkSubmitted,
                child: Container(
                  margin: const EdgeInsets.all(6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child:
                      _opening
                          ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                          : const Text(
                            'Join',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// QR Scanner corner bracket overlay
// ─────────────────────────────────────────────────────────────────────────────
class _ScannerCornerOverlay extends StatelessWidget {
  const _ScannerCornerOverlay();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _CornerBracketPainter(),
        size: Size(MediaQuery.of(context).size.width, 240),
      ),
    );
  }
}

class _CornerBracketPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const color = AppColors.accent;
    final paint =
        Paint()
          ..color = color
          ..strokeWidth = 4.0
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;

    const squareSize = 240.0;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final left = cx - squareSize / 2;
    final top = cy - squareSize / 2;

    const bracketLen = 40.0;
    const r = 24.0;

    void drawCorner(double x, double y, double dx, double dy) {
      final path = Path();
      path.moveTo(x + dx * bracketLen, y);
      path.lineTo(x + dx * r, y);
      path.arcToPoint(
        Offset(x, y + dy * r),
        radius: const Radius.circular(r),
        clockwise: dx != dy,
      );
      path.lineTo(x, y + dy * bracketLen);
      canvas.drawPath(path, paint);
    }

    drawCorner(left, top, 1, 1);
    drawCorner(left + squareSize, top, -1, 1);
    drawCorner(left, top + squareSize, 1, -1);
    drawCorner(left + squareSize, top + squareSize, -1, -1);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
