import 'package:cue_mobile/core/models/transcript_builder.dart';
import 'package:cue_mobile/subtitles.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generates subtitle words with accurate timestamps', () {
    const script = 'Hello world this is a teleprompter test';
    final subtitles = generateSubtitlesFromScript(script, 10.0);

    expect(subtitles.length, 7);
    expect(subtitles.first.text, 'Hello');
    expect(subtitles.first.start, 0.1);
    expect(subtitles.last.text, 'test');
    expect(subtitles.last.end, lessThanOrEqualTo(10.0));
  });

  test('handles empty script input for subtitles', () {
    final emptySubtitles = generateSubtitlesFromScript('', 10.0);
    expect(emptySubtitles, isEmpty);

    final zeroDuration = generateSubtitlesFromScript('Test', 0.0);
    expect(zeroDuration, isEmpty);
  });

  test('builds timed words from streaming speech results', () {
    final builder = TranscriptBuilder();
    builder.update('hello', 1.0);
    builder.update('hello there my', 2.0);
    builder.update('hello there my friend', 2.5);

    final words = builder.words;
    expect(words.map((w) => w.text), ['hello', 'there', 'my', 'friend']);
    for (var i = 1; i < words.length; i++) {
      expect(words[i].start, greaterThanOrEqualTo(words[i - 1].end));
    }
    expect(words.last.end, lessThanOrEqualTo(2.5));
  });

  test('keeps words across listen sessions and ignores silence', () {
    final builder = TranscriptBuilder();
    builder.update('first part', 1.0);
    builder.commitSession();
    builder.update('second', 20.0);

    final words = builder.words;
    expect(words.map((w) => w.text), ['first', 'part', 'second']);
    // The long silence is not stretched over the new word.
    expect(words.last.end - words.last.start, lessThanOrEqualTo(0.5));
  });
}
