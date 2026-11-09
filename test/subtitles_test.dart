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
}
