// lib/screens/host_party_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'dart:async';
import '../constants/colors.dart';
import '../services/shared_queue_service.dart';
import '../services/youtube_mobile_service.dart';
import '../theme/app_theme_controller.dart';

const String _appLink =
    'https://mongobox-79a1f.firebaseapp.com/join-queue.html';

bool get _hostIsDark => AppThemeController.instance.isDarkMode;
Color get _hostBg =>
    _hostIsDark ? const Color(0xFF101316) : const Color(0xFFF5F3EF);
Color get _hostCard =>
    _hostIsDark ? const Color(0xFF171B20) : const Color(0xFFF0EDE7);
Color get _hostCardAlt =>
    _hostIsDark ? const Color(0xFF20252C) : const Color(0xFFF8F4EE);
Color get _hostMutedSurface =>
    _hostIsDark ? const Color(0xFF242A31) : const Color(0xFFECE8E2);
Color get _hostBorder =>
    _hostIsDark ? const Color(0xFF39424B) : const Color(0xFFD8D4CC);
Color get _hostBorderSoft =>
    _hostIsDark ? const Color(0xFF2D343C) : const Color(0xFFE8E4DC);
Color get _hostText => _hostIsDark ? const Color(0xFFF4EFE7) : Colors.black;
Color get _hostMuted =>
    _hostIsDark ? const Color(0xFFA3ACB7) : const Color(0xFF888888);
Color get _hostPrimary => _hostIsDark ? const Color(0xFFF4EFE7) : Colors.black;
Color get _hostOnPrimary =>
    _hostIsDark ? const Color(0xFF101316) : Colors.white;
Color get _hostChip =>
    _hostIsDark ? const Color(0xFF2A3139) : const Color(0xFFE4E0D9);
Color get _hostChipStrong =>
    _hostIsDark ? const Color(0xFF303843) : const Color(0xFFCBC7BF);
Color get _hostGreen => AppColors.accent;
Color get _hostDanger =>
    _hostIsDark ? const Color(0xFFFF8A7A) : const Color(0xFFCC3333);

// ─────────────────────────────────────────────────────────────────────────────
// Host Party Screen
// ─────────────────────────────────────────────────────────────────────────────
class HostPartyScreen extends StatefulWidget {
  const HostPartyScreen({super.key});

  @override
  State<HostPartyScreen> createState() => _HostPartyScreenState();
}

class _HostPartyScreenState extends State<HostPartyScreen>
    with TickerProviderStateMixin {
  static const Duration _playbackPublishInterval = Duration(milliseconds: 50);
  static const int _playbackPublishLeadMs = 10;

  late SharedQueueService _queueService;
  late String _partyId;
  List<Song> queue = [];
  YoutubePlayerController? _playerController;
  final YoutubeMobileService _youtube = YoutubeMobileService();
  final _searchController = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];
  bool _searching = false;
  StreamSubscription<List<Song>>? _queueSubscription;
  Timer? _hostHeartbeatTimer;
  Timer? _playbackSyncTimer;
  bool _isReordering = false;
  bool _hostSessionOpen = false;
  bool _isEndingParty = false;
  String _activeSongId = '';
  bool _playbackStateCleared = true;
  bool? _lastObservedHostIsPlaying;

  @override
  void initState() {
    super.initState();
    _partyId = 'party_${DateTime.now().millisecondsSinceEpoch}';
    _queueService = SharedQueueService(partyId: _partyId);
    _startHostSession();

    _queueSubscription = _queueService.streamQueue().listen((newQueue) {
      if (mounted) {
        setState(() => queue = newQueue);
        _playFirstIfNeeded();
      }
    }, onError: (error) => debugPrint('❌ HOST: Queue stream error: $error'));
  }

  void _startHostSession() {
    _hostSessionOpen = true;
    _lastObservedHostIsPlaying = null;
    unawaited(_queueService.startHostingSession());
    _playbackStateCleared = true;
    unawaited(_queueService.clearPlaybackState());
    _hostHeartbeatTimer?.cancel();
    _hostHeartbeatTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!_hostSessionOpen) return;
      unawaited(_queueService.pulseHostingSession());
    });
    _playbackSyncTimer?.cancel();
    _playbackSyncTimer = Timer.periodic(_playbackPublishInterval, (_) {
      unawaited(_publishPlaybackSnapshot());
    });
  }

  Future<void> _closeHostSession() async {
    if (!_hostSessionOpen) return;
    _hostSessionOpen = false;
    _activeSongId = '';
    _playbackStateCleared = true;
    _lastObservedHostIsPlaying = null;
    _hostHeartbeatTimer?.cancel();
    _playbackSyncTimer?.cancel();
    await _queueService.clearPlaybackState();
    await _queueService.stopHostingSession();
  }

  Future<void> _handleExitParty() async {
    if (_isEndingParty) return;
    _isEndingParty = true;
    await _closeHostSession();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _playFirstIfNeeded() {
    if (queue.isEmpty) {
      _playerController?.removeListener(_handleHostPlayerChanged);
      _playerController?.dispose();
      _activeSongId = '';
      _playbackStateCleared = true;
      _lastObservedHostIsPlaying = null;
      unawaited(_queueService.clearPlaybackState());
      if (mounted) {
        setState(() => _playerController = null);
      } else {
        _playerController = null;
      }
      return;
    }
    final first = queue.first;
    if (_activeSongId == first.id) return;
    _setActiveTrack(first, autoPlay: true);
  }

  void _setActiveTrack(Song song, {required bool autoPlay}) {
    final controller = _playerController;
    if (controller == null) {
      _activeSongId = song.id;
      final nextController = YoutubePlayerController(
        initialVideoId: song.id,
        flags: YoutubePlayerFlags(autoPlay: autoPlay, mute: false),
      );
      nextController.addListener(_handleHostPlayerChanged);
      if (mounted) {
        setState(() => _playerController = nextController);
      } else {
        _playerController = nextController;
      }
      unawaited(_publishPlaybackSnapshot(forceSongId: song.id));
      return;
    }

    if (_activeSongId == song.id) {
      if (autoPlay) {
        controller.play();
      } else {
        controller.pause();
      }
      if (mounted) setState(() {});
      unawaited(_publishPlaybackSnapshot(forceSongId: song.id));
      return;
    }

    _activeSongId = song.id;
    if (autoPlay) {
      controller.load(song.id);
    } else {
      controller.cue(song.id);
    }
    if (mounted) setState(() {});
    unawaited(_publishPlaybackSnapshot(forceSongId: song.id));
  }

  Future<void> _togglePlayback() async {
    final controller = _playerController;
    if (controller == null) return;
    final isPlaying =
        controller.value.isPlaying ||
        controller.value.playerState == PlayerState.playing ||
        controller.value.playerState == PlayerState.buffering;
    if (isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }
    if (mounted) setState(() {});
    await _publishPlaybackSnapshot();
  }

  void _handleHostPlayerChanged() {
    final controller = _playerController;
    if (controller == null || !_hostSessionOpen) return;
    final value = controller.value;
    final playerState = value.playerState;
    final isPlaying =
        value.isPlaying ||
        playerState == PlayerState.playing ||
        playerState == PlayerState.buffering;
    if (_lastObservedHostIsPlaying == isPlaying) return;
    _lastObservedHostIsPlaying = isPlaying;
    unawaited(_publishPlaybackSnapshot());
  }

  Future<void> _publishPlaybackSnapshot({String? forceSongId}) async {
    if (!_hostSessionOpen) return;
    final controller = _playerController;
    final activeSongId = forceSongId ?? _activeSongId;
    if (activeSongId.trim().isEmpty) {
      if (_playbackStateCleared) return;
      _playbackStateCleared = true;
      await _queueService.clearPlaybackState();
      return;
    }

    final value = controller?.value;
    final playerState = value?.playerState;
    final isPlaying =
        value?.isPlaying == true ||
        playerState == PlayerState.playing ||
        playerState == PlayerState.buffering;
    final rawPositionMs = value?.position.inMilliseconds ?? 0;
    final positionMs =
        rawPositionMs + (isPlaying ? _playbackPublishLeadMs : 0);

    _playbackStateCleared = false;
    _lastObservedHostIsPlaying = isPlaying;

    await _queueService.publishPlaybackState(
      songId: activeSongId,
      isPlaying: isPlaying,
      positionMs: positionMs,
    );
  }

  Future<void> _searchSongs() async {
    final q = _searchController.text.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);
    try {
      final results = await _youtube.searchSongs(q, maxResults: 6);
      if (mounted) {
        setState(() {
          _searchResults = results;
          _searching = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _searching = false);
      if (e.toString().contains('quota exceeded') ||
          e.toString().contains('403') ||
          e.toString().contains('quotaExceeded')) {
        _showQuotaExceededDialog();
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  DateTime _getNextQuotaResetTime() {
    final now = DateTime.now();
    const pacificOffset = Duration(hours: -8);
    final pacificNow = now.add(pacificOffset);
    var resetTime = DateTime(pacificNow.year, pacificNow.month, pacificNow.day);
    if (pacificNow.isAfter(resetTime)) {
      resetTime = resetTime.add(const Duration(days: 1));
    }
    return resetTime.subtract(pacificOffset);
  }

  void _showQuotaExceededDialog() {
    final resetTime = _getNextQuotaResetTime();
    final duration = resetTime.difference(DateTime.now());
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    showDialog(
      context: context,
      builder:
          (ctx) => _StyledDialog(
            icon: Icons.schedule_rounded,
            iconColor: const Color(0xFFFF4444),
            title: 'YouTube Quota Exceeded',
            actions: [
              _DialogButton(
                label: 'Got it',
                onPressed: () => Navigator.pop(ctx),
              ),
            ],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'The daily YouTube API search limit has been reached.',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    color: _hostMuted,
                  ),
                ),
                const SizedBox(height: 16),
                _InfoBox(
                  children: [
                    Text(
                      'Resets in',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _hostMuted,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${hours}h ${minutes.toString().padLeft(2, '0')}m',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: _hostDanger,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
    );
  }

  Future<void> _addToQueue(Map<String, dynamic> song) async {
    if (queue.any((s) => s.id == song['id'])) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Already in queue')));
      return;
    }
    await _queueService.addSong(
      Song(
        key: '',
        id: song['id'],
        title: song['title'],
        artist: song['artist'],
        thumbnail: song['thumbnail'],
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ); //.showSnackBar(SnackBar(content: Text('Added "${song['title']}"')));
    }
  }

  Future<void> _playNext() async {
    if (queue.isEmpty) return;
    final currentSong = queue.first;
    final nextSong = queue.length > 1 ? queue[1] : null;

    if (nextSong != null) {
      _setActiveTrack(nextSong, autoPlay: true);
      if (mounted) {
        setState(() {
          queue = queue.sublist(1);
        });
      } else {
        queue = queue.sublist(1);
      }
    } else {
      _playerController?.removeListener(_handleHostPlayerChanged);
      _playerController?.pause();
      _playerController?.dispose();
      _activeSongId = '';
      _playbackStateCleared = true;
      _lastObservedHostIsPlaying = null;
      if (mounted) {
        setState(() {
          _playerController = null;
          queue = const [];
        });
      } else {
        _playerController = null;
        queue = const [];
      }
    }

    await _queueService.remove(currentSong.key);
    await _publishPlaybackSnapshot();
  }

  Future<void> _removeSong(Song song) async {
    await _queueService.remove(song.key);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Removed "${song.title}"')));
    }
  }

  Future<void> _moveSongUp(int index) async {
    if (index <= 0 || index >= queue.length) return;
    final newQueue = [...queue];
    final temp = newQueue[index];
    newQueue[index] = newQueue[index - 1];
    newQueue[index - 1] = temp;
    await _queueService.reorderQueue(newQueue);
  }

  Future<void> _moveSongDown(int index) async {
    if (index < 0 || index >= queue.length - 1) return;
    final newQueue = [...queue];
    final temp = newQueue[index];
    newQueue[index] = newQueue[index + 1];
    newQueue[index + 1] = temp;
    await _queueService.reorderQueue(newQueue);
  }

  Future<void> _clearQueue() async {
    final confirmed = await _showConfirmDialog(
      title: 'Clear Queue',
      message: 'Remove all ${queue.length} songs from the queue?',
      confirmLabel: 'Clear all',
      isDangerous: true,
    );
    if (!confirmed) return;
    _activeSongId = '';
    _playbackStateCleared = true;
    _lastObservedHostIsPlaying = null;
    await _queueService.clear();
    await _queueService.clearPlaybackState();
    _playerController?.removeListener(_handleHostPlayerChanged);
    _playerController?.dispose();
    if (mounted) setState(() => _playerController = null);
  }

  Future<bool> _showConfirmDialog({
    required String title,
    required String message,
    required String confirmLabel,
    bool isDangerous = false,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder:
              (ctx) => _StyledDialog(
                icon:
                    isDangerous
                        ? Icons.warning_rounded
                        : Icons.help_outline_rounded,
                iconColor: isDangerous ? _hostDanger : _hostText,
                title: title,
                actions: [
                  _DialogButton(
                    label: 'Cancel',
                    onPressed: () => Navigator.pop(ctx, false),
                    outlined: true,
                  ),
                  _DialogButton(
                    label: confirmLabel,
                    onPressed: () => Navigator.pop(ctx, true),
                    isDangerous: isDangerous,
                  ),
                ],
                child: Text(
                  message,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    color: _hostMuted,
                  ),
                ),
              ),
        ) ??
        false;
  }

  void _showShareSheet() {
    final partyLink = '$_appLink?partyId=$_partyId';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder:
          (ctx) => _ShareBottomSheet(partyId: _partyId, partyLink: partyLink),
    );
  }

  Future<void> _manualRefresh() async {
    HapticFeedback.lightImpact();
    await _queueService.diagnosticCheck();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Queue synced'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  void dispose() {
    _queueSubscription?.cancel();
    _hostHeartbeatTimer?.cancel();
    _playbackSyncTimer?.cancel();
    _playerController?.removeListener(_handleHostPlayerChanged);
    if (_hostSessionOpen) {
      _hostSessionOpen = false;
      unawaited(_queueService.stopHostingSession());
    }
    _searchController.dispose();
    _playerController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final screenWidth = mq.size.width;
    final screenHeight = mq.size.height;
    final isCompact = screenWidth < 600;
    final hPad = isCompact ? screenWidth * 0.05 : screenWidth * 0.08;
    final vGap = screenHeight < 700 ? 8.0 : 12.0;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_handleExitParty());
      },
      child: Scaffold(
        backgroundColor: _hostBg,
        body: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          behavior: HitTestBehavior.translucent,
          child: SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(hPad, vGap, hPad, vGap),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _HostHeader(
                    partyId: _partyId,
                    queueLength: queue.length,
                    onBack: _handleExitParty,
                    onRefresh: _manualRefresh,
                    onShare: _showShareSheet,
                  ),
                  SizedBox(height: vGap),
                  _NowPlayingCard(
                    playerController: _playerController,
                    nowPlaying: queue.isNotEmpty ? queue.first : null,
                    onPlayPause:
                        _playerController == null ? null : _togglePlayback,
                    onSkip: queue.isEmpty ? null : _playNext,
                    onClear: queue.isEmpty ? null : _clearQueue,
                  ),
                  SizedBox(height: vGap),
                  Expanded(
                    child: _QueueAndSearchPanel(
                      queue: queue,
                      searchController: _searchController,
                      searchResults: _searchResults,
                      isSearching: _searching,
                      isReordering: _isReordering,
                      onToggleReorder:
                          () => setState(() => _isReordering = !_isReordering),
                      onSearch: _searchSongs,
                      onAddSong: _addToQueue,
                      onRemoveSong: _removeSong,
                      onMoveSongUp: _moveSongUp,
                      onMoveSongDown: _moveSongDown,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _HostHeader
// KEY FIX: Title "Host a party" was wrapping to 2 lines because it had to
// share Row space with 3 icon buttons + Share pill. Solution: reduce font
// size to 17 and add maxLines:1 + overflow:ellipsis so it always stays
// on one line regardless of screen width.
// ─────────────────────────────────────────────────────────────────────────────
class _HostHeader extends StatelessWidget {
  const _HostHeader({
    required this.partyId,
    required this.queueLength,
    required this.onBack,
    required this.onRefresh,
    required this.onShare,
  });

  final String partyId;
  final int queueLength;
  final VoidCallback onBack;
  final VoidCallback onRefresh;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Back button
            GestureDetector(
              onTap: onBack,
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: _hostMutedSurface,
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(color: _hostBorder, width: 1),
                ),
                child: Icon(
                  Icons.arrow_back_rounded,
                  size: 18,
                  color: _hostText,
                ),
              ),
            ),
            const SizedBox(width: 10),
            // Title — Expanded so it fills remaining space and ellipsis if needed
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Host a party',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 17, // Reduced from 20/22 → fits on one line
                      fontWeight: FontWeight.w900,
                      color: _hostText,
                      height: 1.1,
                    ),
                  ),
                  SizedBox(height: 1),
                  Text(
                    'You\'re live · manage the room',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _hostMuted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            // Sync
            _HeaderIconBtn(
              icon: Icons.sync_rounded,
              tooltip: 'Sync',
              onTap: onRefresh,
            ),
            const SizedBox(width: 6),
            // Share pill
            GestureDetector(
              onTap: onShare,
              child: Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: _hostPrimary,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.qr_code_2_rounded,
                      size: 15,
                      color: _hostOnPrimary,
                    ),
                    //SizedBox(width: 5),
                    // Text('Share',
                    //     style: TextStyle(
                    //         fontFamily: 'Inter',
                    //         fontSize: 12,
                    //         fontWeight: FontWeight.w800,
                    //         color: Colors.white)),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Stats row
        Row(
          children: [
            _StatChip(
              icon: Icons.tag_rounded,
              label: partyId.replaceFirst('party_', '#'),
            ),
            const SizedBox(width: 8),
            _StatChip(
              icon: Icons.queue_music_rounded,
              label: '$queueLength song${queueLength == 1 ? '' : 's'}',
            ),
            const SizedBox(width: 8),
            _StatChip(
              icon: Icons.fiber_manual_record_rounded,
              label: 'Live',
              iconColor: _hostGreen,
            ),
          ],
        ),
      ],
    );
  }
}

class _HeaderIconBtn extends StatelessWidget {
  const _HeaderIconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: _hostMutedSurface,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: _hostBorder, width: 1),
        ),
        child: Icon(icon, size: 18, color: _hostText),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.icon, required this.label, this.iconColor});
  final IconData icon;
  final String label;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: _hostMutedSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _hostBorder, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: iconColor ?? _hostMuted),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: _hostText,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _NowPlayingCard
// ─────────────────────────────────────────────────────────────────────────────
class _NowPlayingCard extends StatelessWidget {
  const _NowPlayingCard({
    required this.playerController,
    required this.nowPlaying,
    required this.onPlayPause,
    required this.onSkip,
    required this.onClear,
  });

  final YoutubePlayerController? playerController;
  final Song? nowPlaying;
  final VoidCallback? onPlayPause;
  final VoidCallback? onSkip;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final hasTrack = nowPlaying != null;
    Widget buildCard(bool isPlaying) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _hostCard,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: _hostBorder, width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child:
                      hasTrack
                          ? Image.network(
                            nowPlaying!.thumbnail,
                            width: 56,
                            height: 56,
                            fit: BoxFit.cover,
                            errorBuilder:
                                (_, __, ___) => _FallbackThumb(
                                  size: 56,
                                  label: nowPlaying!.title,
                                ),
                          )
                          : _FallbackThumb(size: 56, label: '♪'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: _hostPrimary,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'NOW PLAYING',
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 9,
                                fontWeight: FontWeight.w900,
                                color: _hostOnPrimary,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ),
                          if (hasTrack) ...[
                            const SizedBox(width: 6),
                            _LiveDot(),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        hasTrack ? nowPlaying!.title : 'No track playing',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          color: _hostText,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        hasTrack
                            ? nowPlaying!.artist
                            : 'Add a song to get started',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _hostMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (playerController != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  height: 0.01,
                  child: YoutubePlayer(
                    controller: playerController!,
                    showVideoProgressIndicator: false,
                    onEnded: (_) => onSkip?.call(),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _ActionBtn(
                    icon:
                        isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                    label: isPlaying ? 'Pause' : 'Play',
                    onPressed: hasTrack ? onPlayPause : null,
                    filled: true,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ActionBtn(
                    icon: Icons.skip_next_rounded,
                    label: 'Skip',
                    onPressed: onSkip,
                    filled: false,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ActionBtn(
                    icon: Icons.clear_all_rounded,
                    label: 'Clear',
                    onPressed: onClear,
                    filled: false,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    final controller = playerController;
    if (controller == null) {
      return buildCard(false);
    }

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final playerState = controller.value.playerState;
        final isPlaying =
            controller.value.isPlaying ||
            playerState == PlayerState.playing ||
            playerState == PlayerState.buffering;
        return buildCard(isPlaying);
      },
    );
  }
}

class _LiveDot extends StatefulWidget {
  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = Tween(begin: 0.4, end: 1.0).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder:
          (_, __) => Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Color.fromRGBO(17, 240, 138, _anim.value),
            ),
          ),
    );
  }
}

class _FallbackThumb extends StatelessWidget {
  const _FallbackThumb({required this.size, required this.label});
  final double size;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _hostMutedSurface,
        borderRadius: BorderRadius.circular(size * 0.25),
      ),
      child: Center(
        child: Text(
          label.length > 4 ? label.substring(0, 4) : label,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: size * 0.25,
            fontWeight: FontWeight.w800,
            color: _hostMuted,
          ),
        ),
      ),
    );
  }
}

// FIX: disabled state = warm grey, not black
class _ActionBtn extends StatelessWidget {
  const _ActionBtn({
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.filled,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final isDisabled = onPressed == null;
    final bgColor =
        filled ? (isDisabled ? _hostBorder : _hostPrimary) : Colors.transparent;
    final fgColor =
        filled
            ? (isDisabled ? _hostMuted : _hostOnPrimary)
            : (isDisabled ? _hostMuted : _hostText);
    final borderColor = isDisabled ? _hostBorderSoft : _hostBorder;

    return GestureDetector(
      onTap: onPressed,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(14),
          border: filled ? null : Border.all(color: borderColor, width: 1.5),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: fgColor),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: fgColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _QueueAndSearchPanel
// ─────────────────────────────────────────────────────────────────────────────
class _QueueAndSearchPanel extends StatefulWidget {
  const _QueueAndSearchPanel({
    required this.queue,
    required this.searchController,
    required this.searchResults,
    required this.isSearching,
    required this.isReordering,
    required this.onToggleReorder,
    required this.onSearch,
    required this.onAddSong,
    required this.onRemoveSong,
    required this.onMoveSongUp,
    required this.onMoveSongDown,
  });

  final List<Song> queue;
  final TextEditingController searchController;
  final List<Map<String, dynamic>> searchResults;
  final bool isSearching;
  final bool isReordering;
  final VoidCallback onToggleReorder;
  final VoidCallback onSearch;
  final Future<void> Function(Map<String, dynamic>) onAddSong;
  final Future<void> Function(Song) onRemoveSong;
  final Future<void> Function(int) onMoveSongUp;
  final Future<void> Function(int) onMoveSongDown;

  @override
  State<_QueueAndSearchPanel> createState() => _QueueAndSearchPanelState();
}

class _QueueAndSearchPanelState extends State<_QueueAndSearchPanel> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _hostCard,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: _hostBorder, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                _Tab(
                  label: 'Queue',
                  count: widget.queue.length,
                  selected: _tab == 0,
                  onTap: () => setState(() => _tab = 0),
                ),
                const SizedBox(width: 8),
                _Tab(
                  label: 'Add songs',
                  selected: _tab == 1,
                  onTap: () => setState(() => _tab = 1),
                ),
                const Spacer(),
                if (_tab == 0 && widget.queue.length > 1)
                  GestureDetector(
                    onTap: widget.onToggleReorder,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: widget.isReordering ? _hostPrimary : _hostChip,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.swap_vert_rounded,
                            size: 14,
                            color:
                                widget.isReordering ? _hostGreen : _hostMuted,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            widget.isReordering ? 'Done' : 'Reorder',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color:
                                  widget.isReordering
                                      ? _hostOnPrimary
                                      : _hostText,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: _hostBorder),
          Expanded(
            child:
                _tab == 0
                    ? _QueueTab(
                      queue: widget.queue,
                      isReordering: widget.isReordering,
                      onRemove: widget.onRemoveSong,
                      onMoveUp: widget.onMoveSongUp,
                      onMoveDown: widget.onMoveSongDown,
                    )
                    : _AddSongsTab(
                      searchController: widget.searchController,
                      searchResults: widget.searchResults,
                      isSearching: widget.isSearching,
                      onSearch: widget.onSearch,
                      onAdd: widget.onAddSong,
                    ),
          ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? _hostPrimary : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: selected ? _hostOnPrimary : _hostMuted,
              ),
            ),
            if (count != null && count! > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: selected ? _hostGreen : _hostBorder,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    color: selected ? _hostBg : _hostMuted,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _QueueTab
// ─────────────────────────────────────────────────────────────────────────────
class _QueueTab extends StatelessWidget {
  const _QueueTab({
    required this.queue,
    required this.isReordering,
    required this.onRemove,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  final List<Song> queue;
  final bool isReordering;
  final Future<void> Function(Song) onRemove;
  final Future<void> Function(int) onMoveUp;
  final Future<void> Function(int) onMoveDown;

  @override
  Widget build(BuildContext context) {
    if (queue.isEmpty) {
      return const _EmptyState(
        icon: Icons.queue_music_rounded,
        title: 'Queue is empty',
        message: 'Share the party link and add songs to get the room going.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      itemCount: queue.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (ctx, i) {
        final song = queue[i];
        return _QueueTile(
          song: song,
          isActive: i == 0,
          index: i,
          isReordering: isReordering,
          isFirst: i == 0,
          isLast: i == queue.length - 1,
          onRemove: () => onRemove(song),
          onMoveUp: () => onMoveUp(i),
          onMoveDown: () => onMoveDown(i),
        );
      },
    );
  }
}

class _QueueTile extends StatelessWidget {
  const _QueueTile({
    required this.song,
    required this.isActive,
    required this.index,
    required this.isReordering,
    required this.isFirst,
    required this.isLast,
    required this.onRemove,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  final Song song;
  final bool isActive;
  final int index;
  final bool isReordering;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onRemove;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: isActive ? _hostChip : _hostCardAlt,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isActive ? _hostChipStrong : _hostBorderSoft,
          width: isActive ? 1.5 : 1,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        leading: Stack(
          clipBehavior: Clip.none,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child:
                  song.thumbnail.isNotEmpty
                      ? Image.network(
                        song.thumbnail,
                        width: 52,
                        height: 52,
                        fit: BoxFit.cover,
                        errorBuilder:
                            (_, __, ___) =>
                                _FallbackThumb(size: 52, label: song.title),
                      )
                      : _FallbackThumb(size: 52, label: song.title),
            ),
            if (isActive)
              Positioned(
                bottom: -3,
                right: -3,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: _hostGreen,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.graphic_eq_rounded,
                    size: 11,
                    color: _hostBg,
                  ),
                ),
              ),
          ],
        ),
        title: Text(
          song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: _hostText,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Row(
            children: [
              if (isActive) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: _hostPrimary,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    'PLAYING',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      color: _hostOnPrimary,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _hostMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
        trailing:
            isReordering
                ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ReorderBtn(
                      icon: Icons.keyboard_arrow_up_rounded,
                      onPressed: isFirst ? null : onMoveUp,
                    ),
                    const SizedBox(width: 2),
                    _ReorderBtn(
                      icon: Icons.keyboard_arrow_down_rounded,
                      onPressed: isLast ? null : onMoveDown,
                    ),
                  ],
                )
                : PopupMenuButton<_QueueAction>(
                  onSelected: (action) {
                    if (action == _QueueAction.remove) onRemove();
                  },
                  icon: Icon(
                    Icons.more_horiz_rounded,
                    color: _hostMuted,
                    size: 20,
                  ),
                  color: _hostCardAlt,
                  elevation: 8,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  itemBuilder:
                      (_) => [
                        if (!isActive)
                          const PopupMenuItem(
                            value: _QueueAction.playNext,
                            child: _MenuItemRow(
                              icon: Icons.play_arrow_rounded,
                              label: 'Play next',
                            ),
                          ),
                        const PopupMenuItem(
                          value: _QueueAction.remove,
                          child: _MenuItemRow(
                            icon: Icons.remove_circle_outline_rounded,
                            label: 'Remove',
                            isDestructive: true,
                          ),
                        ),
                      ],
                ),
      ),
    );
  }
}

enum _QueueAction { playNext, remove }

class _ReorderBtn extends StatelessWidget {
  const _ReorderBtn({required this.icon, required this.onPressed});
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: onPressed == null ? 0.25 : 1.0,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: _hostChip,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(icon, size: 18, color: _hostText),
        ),
      ),
    );
  }
}

class _MenuItemRow extends StatelessWidget {
  const _MenuItemRow({
    required this.icon,
    required this.label,
    this.isDestructive = false,
  });
  final IconData icon;
  final String label;
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    final color = isDestructive ? _hostDanger : _hostText;
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 10),
        Text(
          label,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _AddSongsTab
// ─────────────────────────────────────────────────────────────────────────────
class _AddSongsTab extends StatelessWidget {
  const _AddSongsTab({
    required this.searchController,
    required this.searchResults,
    required this.isSearching,
    required this.onSearch,
    required this.onAdd,
  });

  final TextEditingController searchController;
  final List<Map<String, dynamic>> searchResults;
  final bool isSearching;
  final VoidCallback onSearch;
  final Future<void> Function(Map<String, dynamic>) onAdd;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Container(
            decoration: BoxDecoration(
              color: _hostCardAlt,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: _hostBorder, width: 1.5),
            ),
            child: Row(
              children: [
                const SizedBox(width: 12),
                Icon(Icons.search_rounded, color: _hostMuted, size: 18),
                Expanded(
                  child: TextField(
                    controller: searchController,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: _hostText,
                    ),
                    cursorColor: _hostText,
                    decoration: InputDecoration(
                      hintText: 'Search YouTube...',
                      hintStyle: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: _hostMuted,
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: true,
                      fillColor: Colors.transparent,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 13,
                      ),
                    ),
                    onSubmitted: (_) => onSearch(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: GestureDetector(
                    onTap: isSearching ? null : onSearch,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: _hostPrimary,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child:
                          isSearching
                              ? SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: _hostOnPrimary,
                                ),
                              )
                              : Text(
                                'Search',
                                style: TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: _hostOnPrimary,
                                ),
                              ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child:
              searchResults.isEmpty && !isSearching
                  ? const _EmptyState(
                    icon: Icons.music_note_rounded,
                    title: 'Search for songs',
                    message:
                        'Type a song name, artist, or lyrics to find tracks.',
                  )
                  : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                    itemCount: searchResults.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final song = searchResults[i];
                      return _SearchResultTile(
                        song: song,
                        onAdd: () => onAdd(song),
                      );
                    },
                  ),
        ),
      ],
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({required this.song, required this.onAdd});
  final Map<String, dynamic> song;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final thumbnail = song['thumbnail'] as String? ?? '';
    final title = song['title'] as String? ?? 'Untitled';
    final artist = song['artist'] as String? ?? 'Unknown artist';

    return Container(
      decoration: BoxDecoration(
        color: _hostCardAlt,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _hostBorderSoft, width: 1),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child:
              thumbnail.isNotEmpty
                  ? Image.network(
                    thumbnail,
                    width: 52,
                    height: 52,
                    fit: BoxFit.cover,
                    errorBuilder:
                        (_, __, ___) => _FallbackThumb(size: 52, label: title),
                  )
                  : _FallbackThumb(size: 52, label: title),
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: _hostText,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: _hostMuted,
            ),
          ),
        ),
        trailing: GestureDetector(
          onTap: onAdd,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: _hostPrimary,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'Add',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: _hostOnPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ShareBottomSheet
// ─────────────────────────────────────────────────────────────────────────────
class _ShareBottomSheet extends StatelessWidget {
  const _ShareBottomSheet({required this.partyId, required this.partyLink});
  final String partyId;
  final String partyLink;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _hostBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: _hostBorder,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Share your party',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: _hostText,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Guests scan the QR code or tap the link. No sign-in needed.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: _hostMuted,
                ),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: _hostMutedSurface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _hostBorder, width: 1),
                ),
                child: Row(
                  children: [
                    Icon(Icons.tag_rounded, size: 16, color: _hostMuted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        partyId,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: _hostText,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        await Clipboard.setData(ClipboardData(text: partyId));
                        if (!context.mounted) return;
                        Navigator.of(context).pop();
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(
                              'Party ID copied',
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: _hostText,
                              ),
                            ),
                            backgroundColor: _hostCardAlt,
                            behavior: SnackBarBehavior.floating,
                            elevation: 0,
                            margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                              side: BorderSide(color: _hostBorder, width: 1.2),
                            ),
                          ),
                        );
                      },
                      child: Icon(
                        Icons.copy_rounded,
                        size: 16,
                        color: _hostMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _hostCardAlt,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: _hostBorder, width: 1),
                ),
                child: QrImageView(
                  data: partyLink,
                  version: QrVersions.auto,
                  size: 180,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Builder(
                      builder: (buttonContext) {
                        return GestureDetector(
                          onTap: () async {
                            final box =
                                buttonContext.findRenderObject() as RenderBox?;
                            final shareOrigin =
                                box != null && box.hasSize
                                    ? box.localToGlobal(Offset.zero) & box.size
                                    : const Rect.fromLTWH(0, 0, 1, 1);
                            await Share.share(
                              'Join my LyricQsk party\n\n$partyLink',
                              subject: 'LyricQsk Party',
                              sharePositionOrigin: shareOrigin,
                            );
                            if (context.mounted) {
                              Navigator.of(context).pop();
                            }
                          },
                          child: Container(
                            height: 50,
                            decoration: BoxDecoration(
                              color: _hostPrimary,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.share_rounded,
                                  size: 16,
                                  color: _hostOnPrimary,
                                ),
                                SizedBox(width: 8),
                                Text(
                                  'Share link',
                                  style: TextStyle(
                                    fontFamily: 'Inter',
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                    color: _hostOnPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      height: 50,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      decoration: BoxDecoration(
                        color: _hostMutedSurface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: _hostBorder, width: 1),
                      ),
                      child: Center(
                        child: Text(
                          'Close',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: _hostText,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared UI helpers
// ─────────────────────────────────────────────────────────────────────────────
class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });
  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: _hostMutedSurface,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(icon, size: 30, color: _hostMuted),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 15,
                fontWeight: FontWeight.w900,
                color: _hostText,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: _hostMuted,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoBox extends StatelessWidget {
  const _InfoBox({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _hostMutedSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _hostBorder, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

class _StyledDialog extends StatelessWidget {
  const _StyledDialog({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.child,
    required this.actions,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _hostBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, size: 20, color: iconColor),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                      color: _hostText,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            child,
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children:
                  actions
                      .map(
                        (a) => Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: a,
                        ),
                      )
                      .toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _DialogButton extends StatelessWidget {
  const _DialogButton({
    required this.label,
    required this.onPressed,
    this.outlined = false,
    this.isDangerous = false,
  });
  final String label;
  final VoidCallback onPressed;
  final bool outlined;
  final bool isDangerous;

  @override
  Widget build(BuildContext context) {
    final bg =
        isDangerous
            ? _hostDanger
            : outlined
            ? Colors.transparent
            : _hostPrimary;
    final fg = isDangerous || !outlined ? _hostOnPrimary : _hostText;

    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: outlined ? Border.all(color: _hostBorder, width: 1.5) : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: fg,
          ),
        ),
      ),
    );
  }
}
