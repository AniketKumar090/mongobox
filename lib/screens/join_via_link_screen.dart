// lib/screens/join_via_link_screen.dart
// Join a party via pasted link or QR scan. No user info or verification.

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/lyric_screen_theme.dart';
import '../widgets/lyric_page_scaffold.dart';
import 'join_party_screen.dart';

class JoinViaLinkScreen extends StatefulWidget {
  const JoinViaLinkScreen({super.key, this.onBack});

  final VoidCallback? onBack;

  @override
  State<JoinViaLinkScreen> createState() => _JoinViaLinkScreenState();
}

class _JoinViaLinkScreenState extends State<JoinViaLinkScreen> {
  final _linkController = TextEditingController();
  bool _opening = false;

  @override
  void dispose() {
    _linkController.dispose();
    super.dispose();
  }

  Future<void> _openLink(String url) async {
    print('🔗 ========================================');
    print('🔗 GUEST: Opening link: $url');

    final uri = Uri.tryParse(url);
    if (uri == null) {
      print('❌ GUEST: Invalid URL');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Invalid link')));
      }
      return;
    }

    // Try to extract partyId and continue in-app
    final partyId = _extractPartyId(url);
    print('🎪 GUEST: Extracted partyId: $partyId');

    if (partyId != null && partyId.isNotEmpty) {
      print('✅ GUEST: Valid party ID found, joining in-app');
      print('🔗 ========================================');
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

    print('⚠️ GUEST: No party ID found, opening externally');
    print('🔗 ========================================');

    // Fallback: open externally
    setState(() => _opening = true);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      print('❌ GUEST: Error launching URL: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error opening link: $e')));
      }
    }
    if (mounted) setState(() => _opening = false);
  }

  /// Extract partyId from URL
  String? _extractPartyId(String url) {
    try {
      // Handle both full URLs and partial URLs
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        url = 'https://$url';
      }

      final uri = Uri.parse(url);
      final partyId = uri.queryParameters['partyId'];

      print('🔍 URL parsing:');
      print('  - Full URL: $url');
      print('  - Query params: ${uri.queryParameters}');
      print('  - Extracted partyId: $partyId');

      return partyId;
    } catch (e) {
      print('❌ Error extracting partyId: $e');
      return null;
    }
  }

  void _continueInApp() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => JoinPartyScreen(onBack: widget.onBack)),
    );
  }

  void _onLinkSubmitted() {
    final link = _linkController.text.trim();
    if (link.isEmpty) return;
    _openLink(link);
  }

  void _openScanQR() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => _ScanQRScreen(
              onScanned: (url) {
                Navigator.of(context).pop();
                _openLink(url);
              },
              onBack: () => Navigator.of(context).pop(),
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LyricPageScaffold(
      title: 'Join a party',
      subtitle:
          'Paste the host link or scan the room QR code to jump into the shared queue with the same Lyric styling.',
      badge: 'Join flow',
      actions: [
        if (widget.onBack != null)
          OutlinedButton.icon(
            onPressed: widget.onBack,
            icon: const Icon(Icons.close_rounded, size: 18),
            label: const Text('Close'),
          ),
      ],
      child: Builder(
        builder:
            (context) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LyricSectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Bring the invite in',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Paste the party link exactly as the host shared it, or scan the QR code from another phone.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        decoration: BoxDecoration(
                          color:
                              Theme.of(context).colorScheme.tertiaryContainer,
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: TextField(
                          controller: _linkController,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          decoration: InputDecoration(
                            labelText: 'Party link',
                            hintText:
                                'https://mongobox-79a1f.firebaseapp.com/join-queue.html?partyId=...',
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 18,
                            ),
                            suffixIcon: IconButton(
                              icon: const Icon(Icons.open_in_browser_rounded),
                              onPressed: _opening ? null : _onLinkSubmitted,
                              tooltip: 'Open link',
                            ),
                          ),
                          onSubmitted: (_) => _onLinkSubmitted(),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _opening ? null : _openScanQR,
                        icon: const Icon(Icons.qr_code_scanner_rounded),
                        label: const Text('Scan QR code'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _continueInApp,
                        child: const Text('Join without a link'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
      ),
    );
  }
}

class _ScanQRScreen extends StatefulWidget {
  const _ScanQRScreen({required this.onScanned, required this.onBack});

  final void Function(String url) onScanned;
  final VoidCallback onBack;

  @override
  State<_ScanQRScreen> createState() => _ScanQRScreenState();
}

class _ScanQRScreenState extends State<_ScanQRScreen> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
    torchEnabled: false,
  );
  bool _handled = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;
    final code = barcodes.first.rawValue;
    if (code == null || code.isEmpty) return;

    print('📷 ========================================');
    print('📷 QR Code scanned: $code');
    print('📷 ========================================');

    final uri = Uri.tryParse(code);
    if (uri == null || (!uri.hasScheme && !code.startsWith('http'))) {
      print('⚠️ Invalid QR code format');
      return;
    }

    final url = uri.hasScheme ? code : 'https://$code';
    print('✅ Processing URL: $url');

    _handled = true;
    widget.onScanned(url);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: lyricScreenTheme(context),
      child: Builder(
        builder:
            (context) => Scaffold(
              backgroundColor: LyricScreenPalette.background,
              appBar: AppBar(
                title: const Text('Scan QR code'),
                leading: IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: widget.onBack,
                ),
              ),
              body: Stack(
                children: [
                  MobileScanner(controller: _controller, onDetect: _onDetect),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      margin: const EdgeInsets.all(20),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surface.withValues(alpha: 0.95),
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Text(
                        'Center the host QR code inside the frame. We will open the party automatically.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ),
                ],
              ),
            ),
      ),
    );
  }
}
