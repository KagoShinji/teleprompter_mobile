import 'dart:math' as math;

class SubtitleWord {
  String text;
  double start;
  double end;

  SubtitleWord({required this.text, required this.start, required this.end});
}

enum SubtitlePresetStyle { bouncyYellow, neonCyan, minimalDark }

enum SubtitleFontStyle { modern, impact, serif, mono, italic }

List<SubtitleWord> generateSubtitlesFromScript(
  String scriptText,
  double totalDurationSeconds,
) {
  final cleanText = scriptText.trim();
  if (cleanText.isEmpty || totalDurationSeconds <= 0) return [];

  final words = cleanText.split(RegExp(r'\s+'));
  if (words.isEmpty) return [];

  final totalChars = words.fold<int>(0, (sum, w) => sum + w.length);
  if (totalChars == 0) return [];

  final result = <SubtitleWord>[];
  double currentStart = 0.1;

  for (int i = 0; i < words.length; i++) {
    final word = words[i];
    final wordWeight = word.length / totalChars;
    final wordDuration = math.max(0.2, totalDurationSeconds * wordWeight);
    final wordEnd = math.min(totalDurationSeconds, currentStart + wordDuration);

    result.add(
      SubtitleWord(
        text: word,
        start: double.parse(currentStart.toStringAsFixed(2)),
        end: double.parse(wordEnd.toStringAsFixed(2)),
      ),
    );

    currentStart = wordEnd + 0.04;
  }

  return result;
}
