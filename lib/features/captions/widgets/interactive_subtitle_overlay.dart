import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../core/models/subtitle_word.dart';

class InteractiveSubtitleOverlay extends StatefulWidget {
  final List<SubtitleWord> words;
  final VideoPlayerController player;
  final SubtitlePresetStyle style;
  final Function(SubtitleWord word, String newText) onWordEdited;

  const InteractiveSubtitleOverlay({
    super.key,
    required this.words,
    required this.player,
    this.style = SubtitlePresetStyle.bouncyYellow,
    required this.onWordEdited,
  });

  @override
  State<InteractiveSubtitleOverlay> createState() =>
      _InteractiveSubtitleOverlayState();
}

class _InteractiveSubtitleOverlayState
    extends State<InteractiveSubtitleOverlay> {
  static const _hideAfterSilence = 1.5;

  Offset offset = const Offset(0.0, 0.5);

  void _showEditDialog(SubtitleWord word) {
    final controller = TextEditingController(text: word.text);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit word'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Subtitle text',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                widget.onWordEdited(word, controller.text.trim());
              }
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment(offset.dx, offset.dy),
      child: GestureDetector(
        onPanUpdate: (details) {
          final renderBox = context.findRenderObject() as RenderBox?;
          if (renderBox != null && renderBox.hasSize) {
            final size = renderBox.size;
            setState(() {
              final newDx = (offset.dx + (details.delta.dx / (size.width / 2)))
                  .clamp(-0.9, 0.9);
              final newDy = (offset.dy + (details.delta.dy / (size.height / 2)))
                  .clamp(-0.9, 0.9);
              offset = Offset(newDx, newDy);
            });
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: widget.player,
            builder: (context, value, _) {
              final currentSec = value.position.inMilliseconds / 1000.0;
              final activeIndex = widget.words.lastIndexWhere(
                (w) => currentSec >= w.start,
              );
              // Nothing is spoken yet, or the speaker has paused for a while.
              if (activeIndex < 0 ||
                  currentSec >
                      widget.words[activeIndex].end + _hideAfterSilence) {
                return const SizedBox.shrink();
              }

              final chunkStart = (activeIndex ~/ 4) * 4;
              final chunkEnd = math.min(chunkStart + 4, widget.words.length);
              final visibleChunk = widget.words.sublist(chunkStart, chunkEnd);
              final highlight = switch (widget.style) {
                SubtitlePresetStyle.bouncyYellow => const Color(0xffffe500),
                SubtitlePresetStyle.neonCyan => const Color(0xff00f5d4),
                SubtitlePresetStyle.minimalDark => Colors.white,
              };

              return Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (var i = 0; i < visibleChunk.length; i++)
                    _SubtitleText(
                      text: visibleChunk[i].text,
                      active: chunkStart + i == activeIndex,
                      color: highlight,
                      onTap: () => _showEditDialog(visibleChunk[i]),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A subtitle word drawn directly over the video: white fill with a dark
/// outline and soft shadow instead of a background box.
class _SubtitleText extends StatelessWidget {
  final String text;
  final bool active;
  final Color color;
  final VoidCallback onTap;

  const _SubtitleText({
    required this.text,
    required this.active,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w900,
      height: 1.2,
    );
    return GestureDetector(
      onTap: onTap,
      child: AnimatedScale(
        scale: active ? 1.2 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.elasticOut,
        child: Stack(
          children: [
            Text(
              text,
              style: style.copyWith(
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 4
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
        ),
      ),
    );
  }
}
