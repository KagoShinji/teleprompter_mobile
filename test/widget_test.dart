import 'package:cue_mobile/main.dart';
import 'package:cue_mobile/studio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats recording time', () {
    expect(formatTime(0), '00:00');
    expect(formatTime(65), '01:05');
    expect(formatTime(3600), '60:00');
  });

  testWidgets('edits the script and adjusts settings', (tester) async {
    await tester.pumpWidget(const CueApp());
    await tester.pump();

    expect(find.text('Make it sound like you.'), findsOneWidget);
    expect(find.text('Enable camera'), findsOneWidget);
    await tester.tap(find.text('Edit script'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'One two three');
    await tester.pump();
    expect(find.textContaining('3 words'), findsOneWidget);
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Clear script'));
    await tester.tap(find.byTooltip('Clear script'));
    await tester.pump();
    expect(find.textContaining('0 words'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Increase text size').first);
    await tester.tap(find.byTooltip('Increase text size').first);
    await tester.pump();
    expect(find.text('26px'), findsWidgets);
  });

  testWidgets('supports fullscreen preview and portrait/landscape choice', (
    tester,
  ) async {
    await tester.pumpWidget(const CueApp());
    await tester.pump();
    await tester.ensureVisible(find.text('Landscape'));
    await tester.tap(find.text('Landscape'));
    await tester.pump();
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Landscape'))
          .selected,
      isTrue,
    );
    await tester.ensureVisible(find.byTooltip('Fullscreen preview'));
    await tester.tap(find.byTooltip('Fullscreen preview'));
    await tester.pump();
    expect(find.byTooltip('Exit fullscreen preview'), findsOneWidget);
    expect(find.text('Enable camera'), findsOneWidget);
    await tester.tap(find.byTooltip('Exit fullscreen preview'));
    await tester.pump();
    expect(find.text('Make it sound like you.'), findsOneWidget);
  });
}
