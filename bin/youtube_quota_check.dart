import 'dart:io';
import 'package:http/http.dart' as http;
import 'dart:convert';

/// Standalone YouTube Quota Monitor CLI Tool
/// Run: dart bin/youtube_quota_check.dart

const String youtubeApiKey = 'AIzaSyBJzIb7YbZPPL2XuOGlncntEPwkc0JQpmY';
const int defaultDailyQuota = 10000;
const int searchCost = 100;
const int videoCost = 1;

void main() async {
  print('\n🎵 YOUTUBE API QUOTA ANALYZER');
  print('═' * 60);
  
  // Calculate next reset time
  final resetInfo = getNextResetTime();
  
  print('\n⏰ QUOTA RESET SCHEDULE:');
  print('   • Current Time (UTC):      ${DateTime.now().toUtc()}');
  print('   • Current Time (Local):    ${DateTime.now()}');
  print('   • Next Reset (PT Midnight):${resetInfo['resetTime']}');
  print('   • Hours Until Reset:       ${resetInfo['hoursUntilReset']}h ${resetInfo['minutesUntilReset']}m');
  print('   • Days Until Reset:        ${resetInfo['daysUntilReset']} day(s)');
  
  print('\n📊 QUOTA COSTS:');
  print('   • Daily Limit:             $defaultDailyQuota units');
  print('   • Search Query:            $searchCost units each');
  print('   • Video Details (get):     $videoCost unit each');
  
  print('\n💡 USAGE EXAMPLES:');
  print('   • 100 searches:            ${100 * searchCost} units');
  print('   • 1000 video lookups:      ${1000 * videoCost} units');
  print('   • 50 searches + 500 videos: ${50 * searchCost + 500 * videoCost} units');
  
  print('\n📈 ESTIMATED DAILY CAPACITY:');
  print('   • Searches Only:           ${defaultDailyQuota ~/ searchCost} queries/day');
  print('   • Videos Only:             ${defaultDailyQuota ~/ videoCost} video details/day');
  print('   • Mixed (50/50):           ~${defaultDailyQuota ~/ (searchCost / 2 + videoCost / 2).toInt()} operations/day');
  
  print('\n⚡ LIVE API TEST:');
  await testApiConnection();
  
  print('\n═' * 60);
  print('Run your app with quota monitoring to see real-time usage.\n');
}

Map<String, dynamic> getNextResetTime() {
  // YouTube quota resets at midnight Pacific Time (PT)
  final now = DateTime.now();
  final pacificOffset = Duration(hours: -8); // UTC-8 (Standard Time, adjust for DST if needed)
  
  final pacificNow = now.add(pacificOffset);
  var resetTime = DateTime(pacificNow.year, pacificNow.month, pacificNow.day, 0, 0, 0);
  
  // If already past midnight PT today, next reset is tomorrow
  if (pacificNow.isAfter(resetTime)) {
    resetTime = resetTime.add(Duration(days: 1));
  }
  
  final ptResetTime = resetTime.subtract(pacificOffset);
  final now_utc = DateTime.now().toUtc();
  final resetTime_utc = ptResetTime.toUtc();
  final duration = resetTime_utc.difference(now_utc);
  
  return {
    'resetTime': ptResetTime.toString(),
    'hoursUntilReset': duration.inHours,
    'minutesUntilReset': duration.inMinutes % 60,
    'daysUntilReset': duration.inDays,
  };
}

Future<void> testApiConnection() async {
  print('   Testing API connection...');
  
  try {
    final response = await http.get(
      Uri.parse(
        'https://www.googleapis.com/youtube/v3/search?part=snippet&q=test&maxResults=1&key=$youtubeApiKey&type=video',
      ),
    ).timeout(Duration(seconds: 5));
    
    if (response.statusCode == 200) {
      final data = json.decode(response.body) as Map<String, dynamic>;
      print('   ✅ API Connection: SUCCESS');
      print('   • Response Code: 200');
      print('   • Results Found: ${(data['items'] as List?)?.length ?? 0}');
      
      // Try to check for quota headers
      if (response.headers.containsKey('x-goog-ratelimit-user-qps')) {
        print('   • Rate Limit (QPS): ${response.headers['x-goog-ratelimit-user-qps']}');
      }
    } else if (response.statusCode == 403) {
      print('   ❌ API Error: 403 Forbidden');
      print('   • Likely cause: Quota exceeded or invalid API key');
      final errorData = json.decode(response.body);
      print('   • Error: ${errorData['error']}');
    } else {
      print('   ❌ API Error: ${response.statusCode}');
      print('   • Response: ${response.body}');
    }
  } catch (e) {
    print('   ❌ Connection Error: $e');
  }
}
