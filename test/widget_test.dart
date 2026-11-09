import 'package:cue_mobile/main.dart';
import 'package:cue_mobile/studio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
    await tester.scrollUntilVisible(
      find.byTooltip('Increase text size'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Increase text size').first);
    await tester.pump();
    expect(find.text('26px'), findsWidgets);
  });

  testWidgets('restores edited and empty scripts', (tester) async {
    await tester.pumpWidget(const CueApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit script'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Saved script');
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const CueApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit script'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Saved script',
    );
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const CueApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit script'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
  });

  testWidgets('fullscreen settings work without a camera', (tester) async {
    await tester.pumpWidget(const CueApp());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Fullscreen preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Fullscreen preview'));
    await tester.pump();

    expect(find.text('Your camera will appear here'), findsOneWidget);
    expect(find.text('READ ALONG'), findsNothing);

    await tester.tap(find.byTooltip('Teleprompter settings'));
    await tester.pumpAndSettle();
    expect(find.text('Your script'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byTooltip('Increase text size'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Increase text size'));
    await tester.pump();
    expect(find.text('26px'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Teleprompter settings'), findsOneWidget);
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
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 100));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Fullscreen preview'));
    await tester.pump();
    expect(find.byTooltip('Teleprompter settings'), findsOneWidget);
    expect(find.text('Your camera will appear here'), findsOneWidget);
    expect(find.text('Choose your workflow'), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Teleprompter settings'), findsNothing);
    expect(find.text('Choose your workflow'), findsOneWidget);
  });
}
