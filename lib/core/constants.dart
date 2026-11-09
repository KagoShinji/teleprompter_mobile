import 'package:flutter/material.dart';

const String initialScript =
    "Hi there, and welcome.\n\nToday, I want to share a few thoughts on making your next big idea happen. It starts with a simple question: what would you make if you knew you couldn't fail?\n\nGive yourself the space to explore, to experiment, and to get it a little wrong. That's where the interesting things begin.\n\nSo take that first step. Your next chapter is waiting.";

String formatTime(int seconds) =>
    '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';

abstract class AppColors {
  static const Color primaryInk = Color(0xff242620);
  static const Color background = Color(0xfff7f7f5);
  static const Color cardBorder = Color(0xffe2e4dd);
  static const Color heroCardBg = Color(0xffecede8);
  static const Color cameraActiveBg = Color(0xffd8eedc);
  static const Color cameraActiveText = Color(0xff1b4d24);
  static const Color darkBackground = Color(0xff121512);
  static const Color recordRed = Color(0xffd94343);
}
