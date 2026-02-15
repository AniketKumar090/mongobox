// Root widget for mobile: Lyric Play + Host party (all local storage).

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'lyric_home_screen.dart';

class MobileLyricApp extends StatelessWidget {
  const MobileLyricApp({super.key});

  @override
  Widget build(BuildContext context) {
    assert(!kIsWeb, 'MobileLyricApp should only be used on mobile');
    return const LyricHomeScreen();
  }
}
