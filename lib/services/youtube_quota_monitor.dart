import 'dart:io';
import 'package:http/http.dart' as http;
import 'dart:convert';

/// YouTube API Quota Monitor
/// Tracks quota usage and estimates reset time
class YouTubeQuotaMonitor {
  static const String youtubeApiKey = 'AIzaSyBJzIb7YbZPPL2XuOGlncntEPwkc0JQpmY';
  static const int defaultDailyQuota = 10000;
  static const int searchCost = 100; // units per search query
  static const int videoCost = 1; // units per video.get call
  
  static final YouTubeQuotaMonitor _instance = YouTubeQuotaMonitor._internal();
  
  late DateTime _quotaResetTime;
  int _estimatedUsageToday = 0;
  final List<QuotaEvent> _usageLog = [];

  factory YouTubeQuotaMonitor() {
    return _instance;
  }

  YouTubeQuotaMonitor._internal() {
    _updateQuotaResetTime();
  }

  void _updateQuotaResetTime() {
    // YouTube quota resets daily at midnight Pacific Time (PT)
    final now = DateTime.now();
    final pacificTimeOffset = Duration(hours: -7); // PT is UTC-7 (or UTC-8 in winter, but using standard)
    
    final pacificNow = now.add(pacificTimeOffset);
    var resetTime = DateTime(pacificNow.year, pacificNow.month, pacificNow.day, 0, 0, 0);
    
    // If already past midnight PT today, next reset is tomorrow
    if (pacificNow.isAfter(resetTime)) {
      resetTime = resetTime.add(Duration(days: 1));
    }
    
    _quotaResetTime = resetTime.subtract(pacificTimeOffset);
  }

  /// Log a search API call (costs 100 quota units)
  void logSearchCall(String query) {
    _estimatedUsageToday += searchCost;
    _usageLog.add(QuotaEvent(
      type: 'SEARCH',
      cost: searchCost,
      query: query,
      timestamp: DateTime.now(),
    ));
  }

  /// Log a video.get API call (costs 1 quota unit)
  void logVideoCall(List<String> videoIds) {
    final cost = videoCost * videoIds.length;
    _estimatedUsageToday += cost;
    _usageLog.add(QuotaEvent(
      type: 'VIDEO_GET',
      cost: cost,
      query: '${videoIds.length} videos',
      timestamp: DateTime.now(),
    ));
  }

  /// Get current quota status
  QuotaStatus getStatus() {
    _updateQuotaResetTime();
    final remaining = defaultDailyQuota - _estimatedUsageToday;
    final percentUsed = (_estimatedUsageToday / defaultDailyQuota * 100).toStringAsFixed(2);
    
    return QuotaStatus(
      dailyQuotaLimit: defaultDailyQuota,
      estimatedUsage: _estimatedUsageToday,
      estimatedRemaining: remaining,
      percentageUsed: double.parse(percentUsed),
      nextResetTime: _quotaResetTime,
      usageLog: List.from(_usageLog),
    );
  }

  /// Get formatted status report
  String getFormattedReport() {
    final status = getStatus();
    final hoursUntilReset = status.nextResetTime.difference(DateTime.now()).inHours;
    final minutesUntilReset = status.nextResetTime.difference(DateTime.now()).inMinutes % 60;
    
    return '''
╔════════════════════════════════════════════════════════════╗
║          YOUTUBE API QUOTA MONITOR - STATUS REPORT         ║
╚════════════════════════════════════════════════════════════╝

📊 QUOTA USAGE TODAY:
   • Daily Limit:          ${status.dailyQuotaLimit} units
   • Estimated Used:       ${status.estimatedUsage} units
   • Estimated Remaining:  ${status.estimatedRemaining} units
   • Percentage Used:      ${status.percentageUsed}%

⏰ NEXT QUOTA RESET:
   • Reset Time:           ${status.nextResetTime.toString()}
   • Time Until Reset:     $hoursUntilReset hours ${minutesUntilReset} minutes

📈 API COST BREAKDOWN:
   • Search Query:         $searchCost units
   • Video.Get (per):      $videoCost unit(s)

📋 RECENT USAGE LOG (last 10 calls):
${_formatUsageLog(status.usageLog.take(10).toList())}

⚠️  WARNING LEVELS:
   • Safe:      0-7,000 units (70%)
   • Caution:   7,000-9,000 units (90%)
   • Critical:  9,000+ units (90%+)

${_getWarningMessage(status.percentageUsed)}
────────────────────────────────────────────────────────────
''';
  }

  String _formatUsageLog(List<QuotaEvent> events) {
    if (events.isEmpty) {
      return '   No API calls yet today';
    }
    
    return events.asMap().entries.map((entry) {
      final idx = entry.key + 1;
      final event = entry.value;
      return '   $idx. [${event.type}] +${event.cost} units @ ${event.timestamp.toString().split('.')[0]}\n      Query: ${event.query}';
    }).join('\n');
  }

  String _getWarningMessage(double percentUsed) {
    if (percentUsed >= 90) {
      return '🔴 CRITICAL: You are using 90%+ of your daily quota!';
    } else if (percentUsed >= 70) {
      return '🟡 CAUTION: You are using 70%+ of your daily quota.';
    } else {
      return '🟢 OK: Quota usage is healthy.';
    }
  }
}

class QuotaEvent {
  final String type; // SEARCH, VIDEO_GET
  final int cost;
  final String query;
  final DateTime timestamp;

  QuotaEvent({
    required this.type,
    required this.cost,
    required this.query,
    required this.timestamp,
  });
}

class QuotaStatus {
  final int dailyQuotaLimit;
  final int estimatedUsage;
  final int estimatedRemaining;
  final double percentageUsed;
  final DateTime nextResetTime;
  final List<QuotaEvent> usageLog;

  QuotaStatus({
    required this.dailyQuotaLimit,
    required this.estimatedUsage,
    required this.estimatedRemaining,
    required this.percentageUsed,
    required this.nextResetTime,
    required this.usageLog,
  });
}
