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
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0x99000000),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white24),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: widget.player,
            builder: (context, value, _) {
              final currentSec = value.position.inMilliseconds / 1000.0;
              final activeIndex = widget.words.indexWhere(
                (w) => currentSec >= w.start && currentSec <= w.end,
              );

              final visibleIndex = activeIndex >= 0 ? activeIndex : 0;
              final chunkStart = (visibleIndex ~/ 4) * 4;
              final chunkEnd = math.min(chunkStart + 4, widget.words.length);
              final visibleChunk = widget.words.sublist(chunkStart, chunkEnd);

              return Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6,
                runSpacing: 6,
                children: visibleChunk.map((word) {
                  final isActive =
                      currentSec >= word.start && currentSec <= word.end;

                  return GestureDetector(
                    onTap: () => _showEditDialog(word),
                    child: AnimatedScale(
                      scale: isActive ? 1.25 : 1.0,
                      duration: const Duration(milliseconds: 140),
                      curve: Curves.elasticOut,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 140),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: isActive
                              ? switch (widget.style) {
                                  SubtitlePresetStyle.bouncyYellow =>
                                    const Color(0xffffe500),
                                  SubtitlePresetStyle.neonCyan =>
                                    const Color(0xff00f5d4),
                                  SubtitlePresetStyle.minimalDark =>
                                    Colors.white,
                                }
                              : Colors.black38,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          word.text,
                          style: TextStyle(
                            color: isActive ? Colors.black : Colors.white70,
                            fontWeight: isActive
                                ? FontWeight.w900
                                : FontWeight.w600,
                            fontSize: isActive ? 17 : 15,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ),
      ),
    );
  }
}
