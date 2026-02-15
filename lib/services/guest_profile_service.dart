// Local guest profile (name, age, gender) for join flow. Cross-reference when they join again.

import 'package:shared_preferences/shared_preferences.dart';

const _keyGuestName = 'mongobox_guest_name';
const _keyGuestAge = 'mongobox_guest_age';
const _keyGuestGender = 'mongobox_guest_gender';
const _keyGuestLastJoined = 'mongobox_guest_last_joined';

class GuestProfile {
  const GuestProfile({
    required this.name,
    required this.age,
    required this.gender,
    this.lastJoinedAt,
  });

  final String name;
  final int age;
  final String gender;
  final DateTime? lastJoinedAt;

  bool get hasProfile => name.isNotEmpty;
}

class GuestProfileService {
  static Future<GuestProfileService> create() async {
    final prefs = await SharedPreferences.getInstance();
    return GuestProfileService._(prefs);
  }

  GuestProfileService._(this._prefs);

  final SharedPreferences _prefs;

  GuestProfile getProfile() {
    final name = _prefs.getString(_keyGuestName) ?? '';
    final age = _prefs.getInt(_keyGuestAge) ?? 0;
    final gender = _prefs.getString(_keyGuestGender) ?? '';
    final lastJoined = _prefs.getString(_keyGuestLastJoined);
    return GuestProfile(
      name: name,
      age: age,
      gender: gender,
      lastJoinedAt: lastJoined != null ? DateTime.tryParse(lastJoined) : null,
    );
  }

  Future<void> saveProfile({required String name, required int age, required String gender}) async {
    await _prefs.setString(_keyGuestName, name.trim());
    await _prefs.setInt(_keyGuestAge, age);
    await _prefs.setString(_keyGuestGender, gender);
    await _prefs.setString(_keyGuestLastJoined, DateTime.now().toIso8601String());
  }

  Future<void> clearProfile() async {
    await _prefs.remove(_keyGuestName);
    await _prefs.remove(_keyGuestAge);
    await _prefs.remove(_keyGuestGender);
    await _prefs.remove(_keyGuestLastJoined);
  }
}
