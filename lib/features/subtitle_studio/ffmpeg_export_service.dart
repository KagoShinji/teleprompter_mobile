import 'dart:async';
import 'dart:io';
import 'dart:ui' show Offset;

import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/return_code.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/models/subtitle_word.dart';

/// Burns hardcoded subtitles into a video using FFmpeg.
class FfmpegExportService {
  /// Burns the SRT subtitles at [srtPath] into [videoPath].
  ///
  /// [onProgress] is called with a 0–1 progress fraction when statistics
  /// are available. Returns the path of the output video file.
  Future<String> burnSubtitles(
    String videoPath,
    String srtPath, {
    SubtitlePresetStyle style = SubtitlePresetStyle.bouncyYellow,
    SubtitleFontStyle fontStyle = SubtitleFontStyle.modern,
    double fontSize = 22.0,
    bool showBackground = false,
    Offset position = const Offset(0.0, 0.65),
    int? totalDurationMs,
    void Function(double progress)? onProgress,
  }) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final outputPath =
        '${docsDir.path}${Platform.pathSeparator}subtitled_${DateTime.now().millisecondsSinceEpoch}.mp4';

    var normalizedSrt = srtPath.replaceAll('\\', '/');
    if (Platform.isWindows && normalizedSrt.contains(':')) {
      normalizedSrt = normalizedSrt.replaceFirst(':', r'\:');
    }
    final escapedSrtPath = normalizedSrt.replaceAll("'", r"'\''");

    final primaryColour = switch (style) {
      SubtitlePresetStyle.bouncyYellow => '&H0000E5FF',
      SubtitlePresetStyle.neonCyan => '&H00D4F500',
      SubtitlePresetStyle.minimalDark => '&H00FFFFFF',
    };
    final fontSpec = switch (fontStyle) {
      SubtitleFontStyle.modern => 'FontName=sans-serif,Bold=1,Italic=0,Outline=2',
      SubtitleFontStyle.impact =>
        'FontName=sans-serif-condensed,Bold=1,Italic=0,Outline=3',
      SubtitleFontStyle.serif => 'FontName=serif,Bold=1,Italic=0,Outline=2',
      SubtitleFontStyle.mono => 'FontName=monospace,Bold=1,Italic=0,Outline=2',
      SubtitleFontStyle.italic => 'FontName=sans-serif,Bold=1,Italic=1,Outline=2',
    };
    final col = position.dx < -0.3 ? 0 : (position.dx > 0.3 ? 2 : 1);
    final int rowBase;
    final int marginV;
    if (position.dy < -0.3) {
      rowBase = 7;
      marginV = ((position.dy + 0.9) / 0.6 * 60 + 18).round().clamp(16, 90);
    } else if (position.dy > 0.3) {
      rowBase = 1;
      marginV = ((0.9 - position.dy) / 0.6 * 60 + 18).round().clamp(16, 90);
    } else {
      rowBase = 4;
      marginV = 12;
    }
    final alignment = rowBase + col;
    final borderStyle = showBackground ? 3 : 1;
    final forceStyle =
        'FontSize=${fontSize.round()},$fontSpec,PrimaryColour=$primaryColour,OutlineColour=&H00000000,BackColour=&H88000000,BorderStyle=$borderStyle,Alignment=$alignment,MarginV=$marginV';

    final command =
        '-y -i "$videoPath" -vf "subtitles=\'$escapedSrtPath\':force_style=\'$forceStyle\'" -c:v libx264 -crf 23 -c:a copy "$outputPath"';

    final completer = Completer<String>();

    await FFmpegKit.executeAsync(
      command,
      (session) async {
        final returnCode = await session.getReturnCode();
        if (ReturnCode.isSuccess(returnCode)) {
          onProgress?.call(1.0);
          if (!completer.isCompleted) completer.complete(outputPath);
        } else {
          final logs = await session.getLogsAsString();
          if (!completer.isCompleted) {
            completer.completeError(
              Exception('FFmpeg failed (code $returnCode).\n$logs'),
            );
          }
        }
      },
      null,
      onProgress != null
          ? (statistics) {
              final encodedMs = statistics.getTime();
              if (encodedMs > 0) {
                final double fraction;
                if (totalDurationMs != null && totalDurationMs > 0) {
                  fraction = (encodedMs / totalDurationMs).clamp(0.0, 0.99);
                } else {
                  fraction = (encodedMs / (encodedMs + 5000)).clamp(0.0, 0.99);
                }
                onProgress(fraction);
              }
            }
          : null,
    );

    return completer.future;
  }
}
