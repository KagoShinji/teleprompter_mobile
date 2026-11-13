import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../core/models/subtitle_word.dart';

class InteractiveSubtitleOverlay extends StatefulWidget {
  final List<SubtitleWord> words;
  final VideoPlayerController player;
  final SubtitlePresetStyle style;
  final SubtitleFontStyle fontStyle;
  final EdgeInsets padding;
  final Function(SubtitleWord word, String newText) onWordEdited;
  final double fontSize;
  final bool showBackground;
  final bool exactTimelineOnly;
  final Offset? position;
  final ValueChanged<Offset>? onPositionChanged;
  final VoidCallback? onBeforeEdit;

  const InteractiveSubtitleOverlay({
    super.key,
    required this.words,
    required this.player,
    this.style = SubtitlePresetStyle.bouncyYellow,
    this.fontStyle = SubtitleFontStyle.modern,
    this.padding = EdgeInsets.zero,
    required this.onWordEdited,
    this.fontSize = 22.0,
    this.showBackground = false,
    this.exactTimelineOnly = false,
    this.position,
    this.onPositionChanged,
    this.onBeforeEdit,
  });

  @override
  State<InteractiveSubtitleOverlay> createState() =>
      _InteractiveSubtitleOverlayState();
}

class _InteractiveSubtitleOverlayState
    extends State<InteractiveSubtitleOverlay> {
  static const double _phraseHideAfterSilence = 0.3;
  static const double _phraseGapThreshold = 0.35;

  late Offset _offset;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _offset = widget.position ?? const Offset(0.0, 0.65);
  }

  @override
  void didUpdateWidget(covariant InteractiveSubtitleOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.position != null && widget.position != oldWidget.position) {
      _offset = widget.position!;
    }
  }

  Future<void> _showEditDialog(SubtitleWord word) async {
    widget.onBeforeEdit?.call();
    final newText = await showDialog<String>(
      context: context,
      builder: (context) => _EditSubtitleWordDialog(initialText: word.text),
    );
    if (newText != null && newText.isNotEmpty && mounted) {
      widget.onWordEdited(word, newText);
      setState(() {});
    }
  }

  List<SubtitleWord> _phraseWordsAt(int activeIndex) {
    // Walk backwards from chunk boundary so phrases split cleanly across silences.
    final blockBase = (activeIndex ~/ 4) * 4;
    var start = activeIndex;
    while (start > blockBase &&
        widget.words[start].start - widget.words[start - 1].end <=
            _phraseGapThreshold) {
      start--;
    }
    var end = activeIndex + 1;
    final limit = math.min(start + 4, widget.words.length);
    while (end < limit &&
        widget.words[end].start - widget.words[end - 1].end <=
            _phraseGapThreshold) {
      end++;
    }
    return widget.words.sublist(start, end);
  }

  @override
  Widget build(BuildContext context) {
    final highlight = switch (widget.style) {
      SubtitlePresetStyle.bouncyYellow => const Color(0xffffe500),
      SubtitlePresetStyle.neonCyan => const Color(0xff00f5d4),
      SubtitlePresetStyle.minimalDark => Colors.white,
    };

    return Padding(
      padding: widget.padding,
      child: LayoutBuilder(
        builder: (context, constraints) => Align(
          alignment: Alignment(_offset.dx, _offset.dy),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => setState(() => _dragging = true),
            onPanUpdate: (details) {
              final width = constraints.maxWidth;
              final height = constraints.maxHeight;
              if (width > 0 && height > 0) {
                setState(() {
                  final newDx = (_offset.dx + (details.delta.dx / (width / 2)))
                      .clamp(-0.85, 0.85);
                  final newDy = (_offset.dy + (details.delta.dy / (height / 2)))
                      .clamp(-0.85, 0.85);
                  _offset = Offset(newDx, newDy);
                });
                widget.onPositionChanged?.call(_offset);
              }
            },
            onPanEnd: (_) => setState(() => _dragging = false),
            onPanCancel: () => setState(() => _dragging = false),
            child: ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: widget.player,
              builder: (context, value, _) {
                final currentSec = value.position.inMilliseconds / 1000.0;

                if (widget.exactTimelineOnly) {
                  final activeWords = widget.words
                      .where(
                        (w) => currentSec >= w.start && currentSec <= w.end,
                      )
                      .toList();
                  if (activeWords.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return _buildSubtitleContainer(
                    key: ValueKey(
                      'exact_${activeWords.map((w) => identityHashCode(w)).join("_")}',
                    ),
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final w in activeWords)
                          TweenAnimationBuilder<double>(
                            key: ValueKey('pop_${identityHashCode(w)}'),
                            tween: Tween(begin: 0.78, end: 1.15),
                            duration: const Duration(milliseconds: 170),
                            curve: Curves.elasticOut,
                            builder: (context, scale, child) => Transform.scale(
                              scale: scale,
                              child: child,
                            ),
                            child: _SubtitleText(
                              text: w.text,
                              active: true,
                              color: highlight,
                              fontSize: widget.fontSize,
                              fontStyle: widget.fontStyle,
                              animateScale: false,
                              onTap: () => _showEditDialog(w),
                            ),
                          ),
                      ],
                    ),
                  );
                }

                final activeIndex = widget.words.lastIndexWhere(
                  (w) => currentSec >= w.start,
                );
                if (activeIndex < 0 ||
                    currentSec >
                        widget.words[activeIndex].end + _phraseHideAfterSilence) {
                  return const SizedBox.shrink();
                }

                final activeWord = widget.words[activeIndex];
                final visibleChunk = _phraseWordsAt(activeIndex);
                final isWordStillActive = currentSec <= activeWord.end + 0.12;
                final chunkKey =
                    'phrase_${identityHashCode(visibleChunk.first)}_${widget.showBackground}';

                return AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.25),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: _buildSubtitleContainer(
                    key: ValueKey(chunkKey),
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final word in visibleChunk)
                          _SubtitleText(
                            text: word.text,
                            active:
                                identical(word, activeWord) && isWordStillActive,
                            color: highlight,
                            fontSize: widget.fontSize,
                            fontStyle: widget.fontStyle,
                            onTap: () => _showEditDialog(word),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSubtitleContainer({
    required Key key,
    required Widget child,
  }) {
    final padded = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: child,
    );

    if (widget.showBackground || _dragging) {
      return Container(
        key: key,
        decoration: BoxDecoration(
          color: widget.showBackground
              ? Colors.black.withValues(alpha: 0.55)
              : Colors.black.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(12),
          border: _dragging
              ? Border.all(color: Colors.white70, width: 1.5)
              : null,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: padded,
      );
    }

    return KeyedSubtree(key: key, child: padded);
  }
}

/// A subtitle word drawn directly over the video: filled text with a dark
/// outline and soft shadow.
class _SubtitleText extends StatelessWidget {
  final String text;
  final bool active;
  final Color color;
  final VoidCallback onTap;
  final double fontSize;
  final SubtitleFontStyle fontStyle;
  final bool animateScale;

  const _SubtitleText({
    required this.text,
    required this.active,
    required this.color,
    required this.onTap,
    required this.fontSize,
    required this.fontStyle,
    this.animateScale = true,
  });

  TextStyle _baseStyle() {
    return switch (fontStyle) {
      SubtitleFontStyle.modern => TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          height: 1.2,
          letterSpacing: 0.2,
        ),
      SubtitleFontStyle.impact => TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
          fontFamilyFallback: const [
            'sans-serif-condensed',
            'Arial Black',
            'Roboto',
          ],
          height: 1.15,
          letterSpacing: -0.4,
        ),
      SubtitleFontStyle.serif => TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          fontFamilyFallback: const ['Georgia', 'Times New Roman', 'serif'],
          height: 1.2,
          letterSpacing: 0.3,
        ),
      SubtitleFontStyle.mono => TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          fontFamilyFallback: const ['Courier New', 'monospace'],
          height: 1.2,
          letterSpacing: 0.3,
        ),
      SubtitleFontStyle.italic => TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          fontStyle: FontStyle.italic,
          height: 1.2,
          letterSpacing: 0.3,
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final style = _baseStyle();
    final strokeWidth = fontStyle == SubtitleFontStyle.impact ? 5.0 : 4.0;
    final wordStack = Stack(
      children: [
        Text(
          text,
          style: style.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = strokeWidth
              ..strokeJoin = StrokeJoin.round
              ..color = Colors.black,
            shadows: const [
              Shadow(
                color: Colors.black54,
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
        ),
        Text(
          text,
          style: style.copyWith(color: active ? color : Colors.white),
        ),
      ],
    );

    return GestureDetector(
      onTap: onTap,
      child: animateScale
          ? AnimatedScale(
              scale: active ? 1.3 : 1.0,
              duration: const Duration(milliseconds: 180),
              curve: Curves.elasticOut,
              child: wordStack,
            )
          : wordStack,
    );
  }
}

class _EditSubtitleWordDialog extends StatefulWidget {
  const _EditSubtitleWordDialog({required this.initialText});

  final String initialText;

  @override
  State<_EditSubtitleWordDialog> createState() =>
      _EditSubtitleWordDialogState();
}

class _EditSubtitleWordDialogState extends State<_EditSubtitleWordDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit word'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Subtitle text',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (value) => Navigator.pop(context, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
