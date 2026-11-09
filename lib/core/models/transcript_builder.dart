import 'dart:math' as math;

import 'subtitle_word.dart';

/// Turns streaming speech-recognition results into timed [SubtitleWord]s.
///
/// Recognizers only report the full text heard so far, so each time a result
/// grows, the newly appeared words are spread over the time since the last
/// word ended.
class TranscriptBuilder {
  /// Recognizers report words a moment after they were spoken.
  static const recognizerLag = 0.35;
  static const _maxWordSeconds = 0.5;
  static const _minWordSeconds = 0.15;

  final List<SubtitleWord> _committed = [];
  List<SubtitleWord> _session = [];
  double _cursor = 0;

  List<SubtitleWord> get words => [..._committed, ..._session];

  /// Applies the full text recognized so far in the current listen session.
  void update(String recognized, double nowSeconds) {
    final spoken = recognized
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (spoken.isEmpty) return;

    if (spoken.length < _session.length) {
      _session.removeRange(spoken.length, _session.length);
    }
    for (var i = 0; i < _session.length; i++) {
      _session[i].text = spoken[i];
    }

    final fresh = spoken.length - _session.length;
    if (fresh <= 0) return;

    final spanEnd = math.max(
      nowSeconds - recognizerLag,
      _cursor + _minWordSeconds * fresh,
    );
    var spanStart = _cursor;
    if ((spanEnd - spanStart) / fresh > _maxWordSeconds) {
      // Silence preceded these words; don't stretch them across it.
      spanStart = spanEnd - _maxWordSeconds * fresh;
    }
    final slice = (spanEnd - spanStart) / fresh;
    for (var i = 0; i < fresh; i++) {
      _session.add(
        SubtitleWord(
          text: spoken[_session.length],
          start: spanStart + slice * i,
          end: spanStart + slice * (i + 1),
        ),
      );
    }
    _cursor = spanEnd;
  }

  /// Ends the current listen session; the next one starts from empty text.
  void commitSession() {
    _committed.addAll(_session);
    _session = [];
  }
}
