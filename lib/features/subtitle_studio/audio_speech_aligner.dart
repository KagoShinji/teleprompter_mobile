import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/models/subtitle_word.dart';

/// A detected speech activity window on the audio timeline, in seconds.
class SpeechSegment {
  const SpeechSegment({required this.start, required this.end});

  final double start;
  final double end;

  double get duration => math.max(0.0, end - start);
}

/// Inspects 16-bit mono PCM WAV audio to find true acoustic speech windows and
/// snaps drifted LLM timestamps back onto those spoken intervals without
/// breaking videos that contain continuous background music.
class AudioSpeechAligner {
  static const double _frameDurationSec = 0.02; // 20 ms analysis frames
  static const double _mergeSilenceGapSec = 0.24;
  static const double _minSegmentDurationSec = 0.08;
  static const double _clusterSplitGapSec = 0.30;
  static const double _alreadyAlignedToleranceSec = 0.18;
  static const double _maxSnapShiftSec = 5.0;

  /// Reads 16-bit PCM WAV bytes from [wavFile] and detects active speech windows.
  ///
  /// Returns an empty list if the file is invalid, pure silence, or lacks clear
  /// silence gaps (such as music-heavy audio where VAD cannot isolate speech).
  static List<SpeechSegment> detectSpeechSegmentsFromWav(File wavFile) {
    if (!wavFile.existsSync()) return const [];
    final bytes = wavFile.readAsBytesSync();
    final parsed = parseWavPcm16(bytes);
    if (parsed == null || parsed.samples.isEmpty || parsed.sampleRate <= 0) {
      return const [];
    }
    return detectSpeechSegments(parsed.samples, parsed.sampleRate);
  }

  /// Parses RIFF chunks of a 16-bit little-endian PCM WAV file.
  static ({Int16List samples, int sampleRate})? parseWavPcm16(
    Uint8List bytes,
  ) {
    if (bytes.length < 44) return null;
    if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
      return null;
    }

    final view = ByteData.sublistView(bytes);
    int sampleRate = 0;
    int channels = 1;
    int bitsPerSample = 16;
    int offset = 12;

    while (offset + 8 <= bytes.length) {
      final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final chunkSize = view.getUint32(offset + 4, Endian.little);
      final dataStart = offset + 8;
      final dataEnd = math.min(bytes.length, dataStart + chunkSize);

      if (chunkId == 'fmt ' && chunkSize >= 16 && dataStart + 16 <= bytes.length) {
        channels = view.getUint16(dataStart + 2, Endian.little);
        sampleRate = view.getUint32(dataStart + 4, Endian.little);
        bitsPerSample = view.getUint16(dataStart + 14, Endian.little);
      } else if (chunkId == 'data' && bitsPerSample == 16 && channels >= 1) {
        final totalFrames = (dataEnd - dataStart) ~/ (2 * channels);
        final mono = Int16List(totalFrames);
        for (int i = 0; i < totalFrames; i++) {
          int sum = 0;
          final frameBase = dataStart + i * channels * 2;
          for (int c = 0; c < channels; c++) {
            sum += view.getInt16(frameBase + c * 2, Endian.little);
          }
          mono[i] = sum ~/ channels;
        }
        return (samples: mono, sampleRate: sampleRate);
      }

      // RIFF chunks are word-aligned (padded to even byte boundaries).
      offset = dataStart + chunkSize + (chunkSize.isOdd ? 1 : 0);
    }
    return null;
  }

  /// Detects speech islands in normalized mono PCM [samples] at [sampleRate].
  static List<SpeechSegment> detectSpeechSegments(
    Int16List samples,
    int sampleRate,
  ) {
    final samplesPerFrame = math.max(1, (sampleRate * _frameDurationSec).round());
    final frameCount = samples.length ~/ samplesPerFrame;
    if (frameCount < 4) return const [];

    final rmsFrames = List<double>.filled(frameCount, 0.0);
    for (int f = 0; f < frameCount; f++) {
      final start = f * samplesPerFrame;
      final end = start + samplesPerFrame;
      double sumSq = 0;
      for (int i = start; i < end; i++) {
        final s = samples[i].toDouble();
        sumSq += s * s;
      }
      rmsFrames[f] = math.sqrt(sumSq / samplesPerFrame);
    }

    final sorted = [...rmsFrames]..sort();
    final noiseFloor = sorted[((sorted.length - 1) * 0.15).floor()];
    final speechPeak = sorted[((sorted.length - 1) * 0.95).floor()];

    // Skip if flat silence or constant background audio without silent gaps.
    if (speechPeak < 120.0 || speechPeak <= noiseFloor * 2.4) {
      return const [];
    }

    final threshold = math.max(noiseFloor * 2.8, speechPeak * 0.075);
    int activeFrames = 0;
    final raw = <SpeechSegment>[];
    int? segStartFrame;

    for (int f = 0; f < frameCount; f++) {
      final active = rmsFrames[f] >= threshold;
      if (active) activeFrames++;
      if (active && segStartFrame == null) {
        segStartFrame = f;
      } else if (!active && segStartFrame != null) {
        raw.add(
          SpeechSegment(
            start: segStartFrame * _frameDurationSec,
            end: f * _frameDurationSec,
          ),
        );
        segStartFrame = null;
      }
    }
    if (segStartFrame != null) {
      raw.add(
        SpeechSegment(
          start: segStartFrame * _frameDurationSec,
          end: frameCount * _frameDurationSec,
        ),
      );
    }

    // If >88% of audio is above threshold, avoid overriding timestamps.
    if (raw.isEmpty || (activeFrames / frameCount) > 0.88) {
      return const [];
    }

    // Bridge short consonant/breath gaps within continuous spoken phrases.
    final merged = <SpeechSegment>[raw.first];
    for (int i = 1; i < raw.length; i++) {
      final prev = merged.last;
      final next = raw[i];
      if (next.start - prev.end <= _mergeSilenceGapSec) {
        merged[merged.length - 1] =
            SpeechSegment(start: prev.start, end: next.end);
      } else {
        merged.add(next);
      }
    }

    return [
      for (final seg in merged)
        if (seg.duration >= _minSegmentDurationSec) seg,
    ];
  }

  /// Aligns [words] to acoustic [segments] when phrase boundaries drifted into
  /// silence, while preserving already well-aligned word timings.
  static List<SubtitleWord> alignWordsToSegments(
    List<SubtitleWord> words,
    List<SpeechSegment> segments,
  ) {
    if (words.isEmpty || segments.isEmpty) return words;

    final sortedWords = [...words]..sort((a, b) => a.start.compareTo(b.start));
    final clusters = _groupIntoClusters(sortedWords);

    if (clusters.length == segments.length) {
      return _alignOneToOne(clusters, segments);
    }

    // Conservative fallback when segment counts differ: snap clearly off-beat
    // clusters onto the nearest monotonic speech segment within range.
    final aligned = <SubtitleWord>[];
    int nextMinSegIdx = 0;
    for (final cluster in clusters) {
      final bestIdx = _findMatchingSegment(
        cluster: cluster,
        segments: segments,
        minIndex: nextMinSegIdx,
      );
      if (bestIdx != null) {
        nextMinSegIdx = bestIdx + 1;
        aligned.addAll(_fitClusterToSegment(cluster, segments[bestIdx]));
      } else {
        aligned.addAll(cluster);
      }
    }
    return _enforceMonotonic(aligned);
  }

  static List<List<SubtitleWord>> _groupIntoClusters(List<SubtitleWord> words) {
    final clusters = <List<SubtitleWord>>[];
    var current = <SubtitleWord>[words.first];
    for (int i = 1; i < words.length; i++) {
      final w = words[i];
      if (w.start - current.last.end > _clusterSplitGapSec) {
        clusters.add(current);
        current = <SubtitleWord>[w];
      } else {
        current.add(w);
      }
    }
    clusters.add(current);
    return clusters;
  }

  static List<SubtitleWord> _alignOneToOne(
    List<List<SubtitleWord>> clusters,
    List<SpeechSegment> segments,
  ) {
    final out = <SubtitleWord>[];
    for (int i = 0; i < clusters.length; i++) {
      final cluster = clusters[i];
      final seg = segments[i];
      final startDiff = (cluster.first.start - seg.start).abs();
      final endDiff = (cluster.last.end - seg.end).abs();

      if (startDiff > _maxSnapShiftSec && endDiff > _maxSnapShiftSec) {
        out.addAll(cluster);
        continue;
      }
      out.addAll(_fitClusterToSegment(cluster, seg));
    }
    return _enforceMonotonic(out);
  }

  static int? _findMatchingSegment({
    required List<SubtitleWord> cluster,
    required List<SpeechSegment> segments,
    required int minIndex,
  }) {
    final cStart = cluster.first.start;
    final cEnd = cluster.last.end;
    final overlapRatio = _activeOverlapFraction(cStart, cEnd, segments);
    if (overlapRatio >= 0.65) return null;

    int? bestIdx;
    double bestScore = double.infinity;
    final cCenter = (cStart + cEnd) / 2;
    for (int i = minIndex; i < segments.length; i++) {
      final seg = segments[i];
      final sCenter = (seg.start + seg.end) / 2;
      final dist = (cCenter - sCenter).abs();
      if (dist <= _maxSnapShiftSec && dist < bestScore) {
        bestScore = dist;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  static double _activeOverlapFraction(
    double start,
    double end,
    List<SpeechSegment> segments,
  ) {
    final dur = end - start;
    if (dur <= 0.01) return 1.0;
    double overlap = 0;
    for (final s in segments) {
      final a = math.max(start, s.start);
      final b = math.min(end, s.end);
      if (b > a) overlap += (b - a);
    }
    return (overlap / dur).clamp(0.0, 1.0);
  }

  static List<SubtitleWord> _fitClusterToSegment(
    List<SubtitleWord> cluster,
    SpeechSegment seg,
  ) {
    final cStart = cluster.first.start;
    final cEnd = cluster.last.end;
    final startDiff = (cStart - seg.start).abs();
    final endDiff = (cEnd - seg.end).abs();

    // Already synced accurately — keep natural micro-pauses unchanged.
    if (startDiff <= _alreadyAlignedToleranceSec &&
        endDiff <= _alreadyAlignedToleranceSec) {
      return cluster;
    }

    final cSpan = math.max(0.05, cEnd - cStart);
    final sSpan = math.max(0.05 * cluster.length, seg.duration);
    final out = <SubtitleWord>[];

    for (final w in cluster) {
      final relStart = ((w.start - cStart) / cSpan).clamp(0.0, 1.0);
      final relEnd = ((w.end - cStart) / cSpan).clamp(relStart, 1.0);
      final mappedStart = seg.start + relStart * sSpan;
      final mappedEnd = math.max(mappedStart + 0.05, seg.start + relEnd * sSpan);
      out.add(
        SubtitleWord(
          text: w.text,
          start: _roundMs(mappedStart),
          end: _roundMs(mappedEnd),
        ),
      );
    }
    return out;
  }

  static List<SubtitleWord> _enforceMonotonic(List<SubtitleWord> words) {
    final sorted = [...words]..sort((a, b) => a.start.compareTo(b.start));
    for (int i = 0; i < sorted.length; i++) {
      if (i > 0 && sorted[i].start < sorted[i - 1].end) {
        sorted[i].start = sorted[i - 1].end;
      }
      if (sorted[i].end < sorted[i].start + 0.05) {
        sorted[i].end = _roundMs(sorted[i].start + 0.05);
      }
    }
    return sorted;
  }

  static double _roundMs(double seconds) => (seconds * 1000).round() / 1000.0;
}
