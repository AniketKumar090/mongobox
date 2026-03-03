// lib/screens/join_via_link_screen.dart
// Join a party via pasted link or QR scan. No user info or verification.

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:url_launcher/url_launcher.dart';
import 'join_party_screen.dart';

class JoinViaLinkScreen extends StatefulWidget {
  const JoinViaLinkScreen({
    super.key,
    this.onBack,
  });

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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid link')),
        );
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
            builder: (_) => JoinPartyScreen(onBack: widget.onBack, partyId: partyId),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error opening link: $e')),
        );
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
      MaterialPageRoute(
        builder: (_) => JoinPartyScreen(onBack: widget.onBack),
      ),
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
        builder: (_) => _ScanQRScreen(
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
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Join a party'),
        leading: widget.onBack != null
            ? IconButton(icon: const Icon(Icons.close), onPressed: widget.onBack)
            : null,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              "Paste the party link or scan the host's QR code",
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _linkController,
              decoration: InputDecoration(
                labelText: 'Party link',
                hintText: 'https://mongobox-79a1f.firebaseapp.com/join-queue.html?partyId=...',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.open_in_browser),
                  onPressed: _opening ? null : _onLinkSubmitted,
                  tooltip: 'Open link',
                ),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
              onSubmitted: (_) => _onLinkSubmitted(),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _opening ? null : _openScanQR,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QR code'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: _continueInApp,
              child: const Text('Add songs in app instead'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanQRScreen extends StatefulWidget {
  const _ScanQRScreen({
    required this.onScanned,
    required this.onBack,
  });

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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan QR code'),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: widget.onBack),
      ),
      body: MobileScanner(
        controller: _controller,
        onDetect: _onDetect,
      ),
    );
  }
}