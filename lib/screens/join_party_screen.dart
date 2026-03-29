// lib/screens/join_party_screen.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'join_via_link_screen.dart';
import '../services/youtube_mobile_service.dart';
import '../services/shared_queue_service.dart';
import '../widgets/lyric_page_scaffold.dart';

const _partyBg = Color(0xFFEDEAE3);
const _partyCard = Color(0xFFF5F2EA);
const _partyCardInner = Color(0xFFF0EDE6);
const _partyBorder = Color(0x1A000000);
const _partyBorderStrong = Color(0x2E000000);
const _partyDark = Color(0xFF1A1A1A);
const _partyAccent = Color(0xFF11C979);
const _partyAccentBg = Color(0x1F11C979);
const _partyAccentBorder = Color(0x4711C979);
const _partyAccentText = Color(0xFF0A9B5E);
const _partyText = Color(0xFF111111);
const _partyMuted = Color(0xFF7A7570);

class JoinPartyScreen extends StatefulWidget {
  final VoidCallback? onBack;
  final String? partyId;

  const JoinPartyScreen({super.key, this.onBack, this.partyId});

  @override
  State<JoinPartyScreen> createState() => _JoinPartyScreenState();
}

class _JoinPartyScreenState extends State<JoinPartyScreen> {
  static const Duration _partyHeartbeatGrace = Duration(seconds: 35);
  static const Duration _initialStatusGrace = Duration(seconds: 12);
  final _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final YoutubeMobileService _youtube = YoutubeMobileService();
  final DateTime _joinedAt = DateTime.now();
  late SharedQueueService _queueService;
  late String _effectivePartyId;
  StreamSubscription<PartyLiveStatus>? _partyStatusSubscription;
  Timer? _partyStatusTimer;
  List<Map<String, dynamic>> _results = [];
  bool _searching = false;
  final Set<String> _addedIds = {};
  PartyLiveStatus _partyStatus = const PartyLiveStatus();
  bool _partyStatusLoaded = false;
  bool _partyEndedNoticeShown = false;
  bool _hasSeenPartyLive = false;

  @override
  void initState() {
    super.initState();
    _effectivePartyId = widget.partyId ?? 'default_party';

    debugPrint('👥 ========================================');
    debugPrint('👥 GUEST JOINING PARTY');
    debugPrint('👥 Party ID: $_effectivePartyId');
    debugPrint('👥 Firebase Path: parties/$_effectivePartyId/queue');
    debugPrint('👥 ========================================');

    _queueService = SharedQueueService(partyId: _effectivePartyId);
    _partyStatusSubscription = _queueService.streamPartyStatus().listen((
      status,
    ) {
      if (!mounted) return;
      final wasLive = _isPartyLive;
      setState(() {
        _partyStatus = status;
        _partyStatusLoaded = true;
        if (status.isLive ||
            (status.hostLastSeenAt != null && status.endedAt == null)) {
          _hasSeenPartyLive = true;
          _partyEndedNoticeShown = false;
        }
      });
      if (wasLive && !_isPartyLive) {
        _handlePartyEnded();
      }
    });
    _partyStatusTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      if (_partyStatus.hostLastSeenAt == null) return;
      if (_isPartyLive) return;
      _handlePartyEnded();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _partyStatusSubscription?.cancel();
    _partyStatusTimer?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  bool get _isPartyLive {
    if (!_partyStatusLoaded) return true;

    final lastSeenAt = _partyStatus.hostLastSeenAt;
    final heartbeatIsFresh =
        lastSeenAt != null &&
        DateTime.now().difference(lastSeenAt) <= _partyHeartbeatGrace;

    if (_partyStatus.endedAt != null) {
      return false;
    }

    if (_partyStatus.isLive || heartbeatIsFresh) {
      return true;
    }

    final hasPartyStatusEvidence =
        _partyStatus.isLive ||
        _partyStatus.startedAt != null ||
        _partyStatus.hostLastSeenAt != null ||
        _partyStatus.endedAt != null ||
        _hasSeenPartyLive;

    final waitingForInitialSignal =
        !hasPartyStatusEvidence &&
        DateTime.now().difference(_joinedAt) <= _initialStatusGrace;
    if (waitingForInitialSignal) {
      return true;
    }

    if (!hasPartyStatusEvidence) {
      return true;
    }

    return !_hasSeenPartyLive;
  }

  void _handlePartyEnded() {
    if (_partyEndedNoticeShown || !mounted) return;
    _partyEndedNoticeShown = true;
    FocusScope.of(context).unfocus();
    _showThemedSnackBar(
      'This party is no longer live. Song suggestions are off.',
    );
  }

  void _showThemedSnackBar(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: Colors.black,
              height: 1.35,
            ),
          ),
          backgroundColor: const Color(0xFFF8F4EE),
          behavior: SnackBarBehavior.floating,
          elevation: 0,
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(
              color: Color(0xFFD8D4CC),
              width: 1.2,
            ),
          ),
        ),
      );
  }

  Future<void> _search() async {
    if (!_isPartyLive) {
      _handlePartyEnded();
      return;
    }
    final q = _searchController.text.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);
    try {
      final list = await _youtube.searchSongs(q);
      if (!mounted) return;
      setState(() {
        _results = list;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _searching = false);
      _showThemedSnackBar('Could not search songs: $e');
    }
  }

  Future<void> _addToQueue(Map<String, dynamic> song) async {
    if (!_isPartyLive) {
      _handlePartyEnded();
      return;
    }
    final videoId = song['id'] as String? ?? '';
    if (videoId.isEmpty || _addedIds.contains(videoId)) return;

    try {
      debugPrint('➕ GUEST: Adding song to party $_effectivePartyId');
      debugPrint('   Song: ${song['title']}');
      debugPrint('   Video ID: $videoId');

      await _queueService.addSong(
        Song(
          key: '',
          id: song['id'],
          title: song['title'],
          artist: song['artist'],
          thumbnail: song['thumbnail'],
        ),
      );

      debugPrint('✅ GUEST: Song added successfully');

      if (mounted) {
        setState(() => _addedIds.add(videoId));
      }
    } catch (e) {
      debugPrint('❌ GUEST: Error adding song: $e');
      if (mounted) {
        final errorText = e.toString();
        if (errorText.contains('This party has ended')) {
          setState(() {
            _partyStatus = PartyLiveStatus(
              isLive: false,
              startedAt: _partyStatus.startedAt,
              hostLastSeenAt: _partyStatus.hostLastSeenAt,
              endedAt: DateTime.now(),
            );
            _partyStatusLoaded = true;
          });
          _handlePartyEnded();
        } else {
          _showThemedSnackBar('Error adding song: $e');
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _partyBg,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 640;
            final horizontalPadding = compact ? 16.0 : 28.0;

            return Padding(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                14,
                horizontalPadding,
                16,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ── Fixed top sections ──────────────────────────────
                      _buildHeaderCard(context, compact),
                      const SizedBox(height: 10),
                      _buildStatusBar(),
                      const SizedBox(height: 10),
                      _buildSearchCard(),
                      const SizedBox(height: 10),

                      // ── Results: Expanded fills all remaining space ──────
                      Expanded(
                        child: _buildResultsCard(),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ── Header ──────────────────────────────────────────────────────────────────

  Widget _buildHeaderCard(BuildContext context, bool compact) {
    return Container(
      padding: EdgeInsets.all(compact ? 16 : 20),
      decoration: BoxDecoration(
        color: _partyCard,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _partyBorderStrong, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _BackButton(
                onTap: widget.onBack ?? () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: 10),
              const _GuestBadge(),
            ],
          ),
          const SizedBox(height: 14),
          const Text(
            'Join a party',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 30,
              fontWeight: FontWeight.w800,
              color: _partyText,
              letterSpacing: -0.8,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Search anything you want to hear, then send it straight to the host queue.',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: _partyMuted,
              height: 1.5,
            ),
          ),
          // ── ADD THIS BLOCK ──────────────────────────────────────
          if (!_isPartyLive) ...[
            const SizedBox(height: 14),
            GestureDetector(
              onTap: () {
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(
                    builder: (_) => JoinViaLinkScreen(onBack: widget.onBack),
                  ),
                );
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 13),
                decoration: BoxDecoration(
                  color: _partyDark,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_rounded, size: 16, color: Colors.white),
                    SizedBox(width: 6),
                    Text(
                      'Join a new party',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          // ────────────────────────────────────────────────────────
       
        ],
      ),
    );
  }

  // ── Status bar ───────────────────────────────────────────────────────────────

  Widget _buildStatusBar() {
    final isLive = _isPartyLive;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: isLive ? _partyDark : const Color(0xFF3A2B2B),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.queue_music_rounded,
              color: Colors.white,
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'PARTY ID',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: Colors.white38,
                    letterSpacing: 0.08,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  _effectivePartyId,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: -0.1,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(
              color: isLive ? _partyAccentBg : const Color(0x33FF6B6B),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color:
                    isLive
                        ? _partyAccentBorder
                        : const Color(0x66FF6B6B),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: isLive ? _partyAccent : const Color(0xFFFF6B6B),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  isLive ? 'Live' : 'Ended',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color:
                        isLive ? _partyAccent : const Color(0xFFFF9A9A),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Search card ──────────────────────────────────────────────────────────────

  Widget _buildSearchCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _partyCard,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _partyBorderStrong, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Search songs',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: _partyText,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Any language. Tap add — your pick goes straight to the host.',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: _partyMuted,
              height: 1.45,
            ),
          ),
          if (!_isPartyLive) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFEFEF),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFFD1D1)),
              ),
              child: const Text(
                'This party has ended. You can still view the room, but new suggestions are disabled.',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFB14545),
                  height: 1.4,
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          _buildSearchField(),
        ],
      ),
    );
  }

  Widget _buildSearchField() {
    return ListenableBuilder(
      listenable: _searchFocusNode,
      builder: (context, _) {
        final hasFocus = _searchFocusNode.hasFocus;
        return Container(
          decoration: BoxDecoration(
            color: _partyCardInner,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: hasFocus ? _partyAccent : _partyBorderStrong,
              width: hasFocus ? 1.5 : 1.0,
            ),
          ),
          child: Row(
            children: [
              const SizedBox(width: 13),
              Icon(
                Icons.search_rounded,
                color: hasFocus ? _partyAccentText : _partyMuted,
                size: 18,
              ),
              Expanded(
                child: Theme(
                  data: Theme.of(context).copyWith(
                    textSelectionTheme: const TextSelectionThemeData(
                      cursorColor: _partyText,
                      selectionColor: Color(0x3311C979),
                      selectionHandleColor: _partyText,
                    ),
                  ),
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    maxLines: 1,
                    enabled: _isPartyLive,
                    cursorColor: _partyText,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: _partyText,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Search songs (any language)…',
                      hintStyle: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        color: _partyMuted,
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: true,
                      fillColor: Colors.transparent,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 14,
                      ),
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _SearchButton(
                  loading: _searching,
                  onTap: _searching || !_isPartyLive ? null : _search,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Results card — fills all remaining vertical space ────────────────────────
  //
  // The card is wrapped in Expanded in the parent Column, so Flutter gives it
  // exactly the leftover height after the header, status bar, and search card.
  //
  // Inside:
  //   • Empty / loading  → content is centered with mainAxisAlignment.center
  //                         inside a Column that itself fills the card via
  //                         double.infinity height.
  //   • With results     → fixed heading rows + Expanded ListView that scrolls
  //                         when tracks overflow, never growing past the card.

  Widget _buildResultsCard() {
    // Container paints the border + card background.
    // ClipRRect sits INSIDE so it clips the child content without touching
    // the border — radius is 1px smaller to sit just inside the stroke.
    return Container(
      decoration: BoxDecoration(
        color: _partyCard,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _partyBorderStrong, width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(21),
        child: _searching
            ? const Center(
                child: CircularProgressIndicator(
                  color: _partyAccent,
                  strokeWidth: 2.5,
                ),
              )
            : !_isPartyLive
                ? _buildPartyEndedFill()
            : _results.isEmpty
                ? _buildEmptyFill()
                : _buildResultsFill(),
      ),
    );
  }

  /// Empty state — fills the card wall-to-wall and centers the icon + text
  /// regardless of how tall the card happens to be on any given device.
  Widget _buildEmptyFill() {
    return Container(
      width: double.infinity,
      color: _partyCardInner,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _partyBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _partyBorderStrong),
            ),
            child: const Icon(
              Icons.search_rounded,
              size: 20,
              color: _partyMuted,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Search for songs to add',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: _partyText,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Works in any language.',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: _partyMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPartyEndedFill() {
    return Container(
      width: double.infinity,
      color: _partyCardInner,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFFFFEFEF),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFFFD1D1)),
            ),
            child: const Icon(
              Icons.portable_wifi_off_rounded,
              size: 22,
              color: Color(0xFFB14545),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Party ended',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: _partyText,
            ),
          ),
          const SizedBox(height: 6),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 30),
            child: Text(
              'The host is no longer live, so new song suggestions have been turned off.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: _partyMuted,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Results list — fixed heading + scrollable track list that fills the card.
  Widget _buildResultsFill() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text(
                'Results',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: _partyText,
                  letterSpacing: -0.3,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'Tap add to send it to the host queue.',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: _partyMuted,
                ),
              ),
              SizedBox(height: 12),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            itemCount: _results.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (ctx, i) {
              final song = _results[i];
              final id = song['id'] as String? ?? '';
              final added = _addedIds.contains(id);
              return _JoinResultTile(
                title: song['title'] as String? ?? 'Untitled',
                artist: song['artist'] as String? ?? 'Unknown artist',
                thumbnail: song['thumbnail'] as String? ?? '',
                added: added,
                onPressed:
                    added || !_isPartyLive ? null : () => _addToQueue(song),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ── Subwidgets ────────────────────────────────────────────────────────────────

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _partyBorderStrong),
        ),
        child: const Icon(
          Icons.arrow_back_ios_new_rounded,
          size: 15,
          color: _partyText,
        ),
      ),
    );
  }
}

class _GuestBadge extends StatelessWidget {
  const _GuestBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: _partyAccentBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _partyAccentBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: _partyAccent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          const Text(
            'Guest mode',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: _partyAccentText,
              letterSpacing: 0.02,
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchButton extends StatelessWidget {
  const _SearchButton({this.loading = false, this.onTap});
  final bool loading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: disabled ? const Color(0xFFCCCAC4) : _partyDark,
          borderRadius: BorderRadius.circular(10),
        ),
        child: loading
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Text(
                'Search',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: disabled ? _partyMuted : Colors.white,
                ),
              ),
      ),
    );
  }
}

class _JoinResultTile extends StatelessWidget {
  const _JoinResultTile({
    required this.title,
    required this.artist,
    required this.thumbnail,
    required this.added,
    required this.onPressed,
  });

  final String title;
  final String artist;
  final String thumbnail;
  final bool added;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: added ? const Color(0xFFEBF9F3) : _partyCardInner,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: added ? _partyAccentBorder : _partyBorder,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: LyricThumbnailAvatar(imageUrl: thumbnail, size: 46),
        title: Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: _partyText,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: _partyMuted,
            ),
          ),
        ),
        trailing: added ? const _AddedBadge() : _AddButton(onTap: onPressed),
      ),
    );
  }
}

class _AddedBadge extends StatelessWidget {
  const _AddedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: _partyAccentBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _partyAccentBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.check_rounded, size: 13, color: _partyAccentText),
          SizedBox(width: 4),
          Text(
            'Added',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: _partyAccentText,
            ),
          ),
        ],
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: _partyDark,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text(
          'Add',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
