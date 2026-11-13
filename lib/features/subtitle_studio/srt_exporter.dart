import 'dart:io';
import 'dart:math' as math;

import '../../core/models/subtitle_word.dart';

/// Exports a list of [SubtitleWord]s to an SRT file.
class SrtExporter {
  /// Writes an SRT file inside [outputDir] for [words].
  ///
  /// When [exactTimelineOnly] is true, each [SubtitleWord] keeps its exact
  /// timeline window (`start`..`end`) so nothing appears during silent gaps.
  /// When false, nearby words are grouped in chunks of up to 4 words without
  /// bridging silence gaps longer than 0.35s.
  static Future<String> toSrtFile(
    List<SubtitleWord> words,
    String outputDir, {
    bool exactTimelineOnly = false,
  }) async {
    if (words.isEmpty) {
      throw Exception('Cannot export subtitles: there are no subtitle words.');
    }

    final sorted = [...words]..sort((a, b) => a.start.compareTo(b.start));
    final buffer = StringBuffer();
    final chunks = exactTimelineOnly
        ? [for (final w in sorted) [w]]
        : _chunkWords(sorted, chunkSize: 4);

    for (int i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      final startMs = math.max(0, (chunk.first.start * 1000).round());
      final endMs = math.max(
        startMs + 50,
        (chunk.last.end * 1000).round(),
      );

      buffer
        ..writeln(i + 1)
        ..writeln(
            '${_formatTimestamp(startMs)} --> ${_formatTimestamp(endMs)}')
        ..writeln(chunk.map((w) => w.text).join(' '))
        ..writeln();
    }

    final outputPath =
        '$outputDir${Platform.pathSeparator}subtitles_${DateTime.now().millisecondsSinceEpoch}.srt';
    await File(outputPath).writeAsString(buffer.toString());
    return outputPath;
  }

  static List<List<SubtitleWord>> _chunkWords(
    List<SubtitleWord> words, {
    required int chunkSize,
  }) {
    final chunks = <List<SubtitleWord>>[];
    var current = <SubtitleWord>[];
    for (final word in words) {
      final hasLargeGap =
          current.isNotEmpty && (word.start - current.last.end) > 0.35;
      if (current.length >= chunkSize || hasLargeGap) {
        chunks.add(current);
        current = <SubtitleWord>[];
      }
      current.add(word);
    }
    if (current.isNotEmpty) {
      chunks.add(current);
    }
    return chunks;
  }

  /// Formats milliseconds as `HH:MM:SS,mmm` (SRT timestamp format).
  static String _formatTimestamp(int totalMs) {
    final ms = totalMs % 1000;
    final totalSeconds = totalMs ~/ 1000;
    final seconds = totalSeconds % 60;
    final totalMinutes = totalSeconds ~/ 60;
    final minutes = totalMinutes % 60;
    final hours = totalMinutes ~/ 60;

    return '${_pad2(hours)}:${_pad2(minutes)}:${_pad2(seconds)},${_pad3(ms)}';
  }

  static String _pad2(int v) => v.toString().padLeft(2, '0');
  static String _pad3(int v) => v.toString().padLeft(3, '0');
}
