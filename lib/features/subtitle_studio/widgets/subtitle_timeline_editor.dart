import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../core/models/subtitle_word.dart';

const double _kPixelsPerSecond = 100.0;
const double _kRulerHeight = 26.0;
const double _kTrackHeight = 76.0;
const double _kTimelineCanvasHeight = _kRulerHeight + _kTrackHeight; // 102 px
const double _kMinChipWidth = 42.0;
const double _kChipHeight = 28.0;

const Color _kTrackBg = Color(0xff141416);
const Color _kRulerBg = Color(0xff1c1c20);
const Color _kChipActiveColor = Color(0xffffe500);
const Color _kChipIdleColor = Color(0xff3a351e);
const Color _kPlayheadColor = Color(0xffff4d4f);

/// CapCut-style horizontal timeline showing timed [SubtitleWord] chips below
/// a time ruler with a live playhead, scrubbing, drag-to-shift, and word CRUD.
class SubtitleTimelineEditor extends StatefulWidget {
  const SubtitleTimelineEditor({
    super.key,
    required this.words,
    required this.player,
    required this.totalDurationSeconds,
    required this.onWordMoved,
    required this.onWordEdited,
    required this.onWordDeleted,
    required this.onWordAdded,
    required this.onSeek,
  });

  final List<SubtitleWord> words;
  final VideoPlayerController player;
  final double totalDurationSeconds;
  final void Function(SubtitleWord word) onWordMoved;
  final void Function(SubtitleWord word, String newText) onWordEdited;
  final void Function(SubtitleWord word) onWordDeleted;
  final void Function(SubtitleWord word) onWordAdded;
  final void Function(double seconds) onSeek;

  @override
  State<SubtitleTimelineEditor> createState() => _SubtitleTimelineEditorState();
}

class _SubtitleTimelineEditorState extends State<SubtitleTimelineEditor> {
  late final ScrollController _scrollController;
  bool _userDraggingTimeline = false;
  SubtitleWord? _selectedWord;

  double get _safeDuration => math.max(1.0, widget.totalDurationSeconds);
  double get _timelineWidth => _safeDuration * _kPixelsPerSecond;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    widget.player.addListener(_syncScrollWithPlayback);
  }

  @override
  void didUpdateWidget(covariant SubtitleTimelineEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_syncScrollWithPlayback);
      widget.player.addListener(_syncScrollWithPlayback);
    }
    if (_selectedWord != null && !widget.words.contains(_selectedWord)) {
      _selectedWord = null;
    }
  }

  @override
  void dispose() {
    widget.player.removeListener(_syncScrollWithPlayback);
    _scrollController.dispose();
    super.dispose();
  }

  void _syncScrollWithPlayback() {
    if (!mounted ||
        _userDraggingTimeline ||
        !_scrollController.hasClients ||
        !widget.player.value.isPlaying) {
      return;
    }
    final posSec = widget.player.value.position.inMilliseconds / 1000.0;
    final playheadX = (posSec / _safeDuration) * _timelineWidth;
    final viewport = _scrollController.position.viewportDimension;
    final currentOffset = _scrollController.offset;
    final maxScroll = _scrollController.position.maxScrollExtent;

    if (playheadX > currentOffset + viewport * 0.78 ||
        playheadX < currentOffset + viewport * 0.1) {
      final target = (playheadX - viewport * 0.25).clamp(0.0, maxScroll);
      if ((target - currentOffset).abs() > 16) {
        _scrollController.jumpTo(target);
      }
    }
  }

  void _seekFromLocalDx(double dx) {
    final seconds = (dx / _timelineWidth) * _safeDuration;
    widget.onSeek(seconds.clamp(0.0, _safeDuration));
  }

  SubtitleWord? _targetEditWord(double posSec) {
    if (_selectedWord != null && widget.words.contains(_selectedWord)) {
      return _selectedWord;
    }
    for (final w in widget.words) {
      if (posSec >= w.start && posSec <= w.end) {
        return w;
      }
    }
    return null;
  }

  Widget _buildHeader(double posSec) {
    final editTarget = _targetEditWord(posSec);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        children: [
          const Icon(Icons.graphic_eq, size: 15, color: Color(0xffffe500)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'TIMELINE (${widget.words.length} words)',
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (editTarget != null) ...[
            TextButton.icon(
              onPressed: () => _showEditDialog(editTarget),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                backgroundColor: Colors.white12,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: const Icon(Icons.edit, size: 13),
              label: const Text(
                'Edit',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 6),
          ],
          TextButton.icon(
            onPressed: _showAddWordDialog,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xffffe500),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              backgroundColor: const Color(0x22ffe500),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            icon: const Icon(Icons.add, size: 15),
            label: const Text(
              'Add Word',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRuler() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) => _seekFromLocalDx(details.localPosition.dx),
      onHorizontalDragStart: (_) => _userDraggingTimeline = true,
      onHorizontalDragUpdate: (details) =>
          _seekFromLocalDx(details.localPosition.dx),
      onHorizontalDragEnd: (_) => _userDraggingTimeline = false,
      onHorizontalDragCancel: () => _userDraggingTimeline = false,
      child: Container(
        width: _timelineWidth,
        height: _kRulerHeight,
        color: _kRulerBg,
        child: CustomPaint(painter: _RulerPainter(_safeDuration)),
      ),
    );
  }

  Widget _buildPlayhead(double posSec) {
    final x = (posSec / _safeDuration).clamp(0.0, 1.0) * _timelineWidth;
    return Positioned(
      left: x - 5,
      top: 0,
      bottom: 0,
      child: IgnorePointer(
        child: SizedBox(
          width: 10,
          child: Column(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  color: _kPlayheadColor,
                  shape: BoxShape.circle,
                ),
              ),
              Expanded(
                child: Center(
                  child: Container(
                    width: 2,
                    color: _kPlayheadColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildStaggeredChips(double posSec) {
    final sorted = [...widget.words]..sort((a, b) => a.start.compareTo(b.start));
    double lane0Right = -1000;
    double lane1Right = -1000;

    return [
      for (final word in sorted)
        Builder(
          builder: (context) {
            final leftPos = (word.start / _safeDuration) * _timelineWidth;
            final chipWidth = math.max(
              _kMinChipWidth,
              ((word.end - word.start) / _safeDuration) * _timelineWidth,
            );
            final int lane;
            if (leftPos >= lane0Right + 3) {
              lane = 0;
              lane0Right = leftPos + chipWidth;
            } else if (leftPos >= lane1Right + 3) {
              lane = 1;
              lane1Right = leftPos + chipWidth;
            } else {
              lane = lane0Right <= lane1Right ? 0 : 1;
              if (lane == 0) {
                lane0Right = leftPos + chipWidth;
              } else {
                lane1Right = leftPos + chipWidth;
              }
            }
            final double topOffset = lane == 0 ? 7.0 : 41.0;
            final isActive = posSec >= word.start && posSec <= word.end;
            final isSelected = identical(word, _selectedWord);

            return _buildChip(
              word: word,
              leftPos: leftPos,
              chipWidth: chipWidth,
              topOffset: topOffset,
              isActive: isActive,
              isSelected: isSelected,
            );
          },
        ),
    ];
  }

  Widget _buildChip({
    required SubtitleWord word,
    required double leftPos,
    required double chipWidth,
    required double topOffset,
    required bool isActive,
    required bool isSelected,
  }) {
    return Positioned(
      left: leftPos,
      top: topOffset,
      child: GestureDetector(
        onTap: () {
          setState(() => _selectedWord = word);
          widget.onSeek(word.start);
        },
        onHorizontalDragStart: (_) {
          _userDraggingTimeline = true;
          setState(() => _selectedWord = word);
        },
        onHorizontalDragUpdate: (details) {
          final deltaSecs =
              details.delta.dx / _timelineWidth * _safeDuration;
          final duration = math.max(0.05, word.end - word.start);
          final maxStart = math.max(0.0, _safeDuration - duration);
          final nextStart = (word.start + deltaSecs).clamp(0.0, maxStart);
          setState(() {
            word.start = nextStart;
            word.end = nextStart + duration;
          });
          widget.onWordMoved(word);
        },
        onHorizontalDragEnd: (_) => _userDraggingTimeline = false,
        onHorizontalDragCancel: () => _userDraggingTimeline = false,
        onLongPress: () => _showEditDialog(word),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          width: chipWidth,
          height: _kChipHeight,
          decoration: BoxDecoration(
            color: isActive ? _kChipActiveColor : _kChipIdleColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected
                  ? const Color(0xff00f5d4)
                  : (isActive ? Colors.white : const Color(0x88ffe500)),
              width: (isSelected || isActive) ? 1.8 : 1,
            ),
            boxShadow: isActive
                ? const [
                    BoxShadow(
                      color: Color(0x66ffe500),
                      blurRadius: 8,
                    ),
                  ]
                : null,
          ),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            word.text,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: TextStyle(
              color: isActive ? Colors.black : Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 11,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showEditDialog(SubtitleWord word) async {
    final result = await showDialog<({String action, String text, double start, double end})>(
      context: context,
      builder: (_) => _WordEditorDialog(
        word: word,
        safeDuration: _safeDuration,
      ),
    );

    if (result == null || !mounted) return;

    if (result.action == 'delete') {
      if (_selectedWord == word) _selectedWord = null;
      widget.onWordDeleted(word);
      if (mounted) setState(() {});
    } else if (result.action == 'save') {
      var changed = false;
      if (result.start != word.start || result.end != word.end) {
        word.start = result.start;
        word.end = result.end;
        widget.onWordMoved(word);
        changed = true;
      }
      if (result.text.isNotEmpty && result.text != word.text) {
        widget.onWordEdited(word, result.text);
        changed = true;
      }
      if (changed && mounted) setState(() {});
    }
  }

  Future<void> _showAddWordDialog() async {
    final currentPos =
        (widget.player.value.position.inMilliseconds / 1000.0)
            .clamp(0.0, _safeDuration);

    final text = await showDialog<String>(
      context: context,
      builder: (_) => _AddWordDialog(insertAtSeconds: currentPos),
    );

    if (text != null && text.isNotEmpty && mounted) {
      const defaultDuration = 0.5;
      final start = math.min(currentPos, math.max(0.0, _safeDuration - 0.1));
      final newWord = SubtitleWord(
        text: text,
        start: start,
        end: math.min(start + defaultDuration, _safeDuration),
      );
      widget.onWordAdded(newWord);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _kTrackBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      clipBehavior: Clip.antiAlias,
      child: ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: widget.player,
        builder: (context, value, _) {
          final posSec = value.position.inMilliseconds / 1000.0;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeader(posSec),
              SizedBox(
                height: _kTimelineCanvasHeight,
                child: NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification is ScrollStartNotification &&
                        notification.dragDetails != null) {
                      _userDraggingTimeline = true;
                    } else if (notification is ScrollEndNotification) {
                      _userDraggingTimeline = false;
                    }
                    return false;
                  },
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: _timelineWidth,
                      height: _kTimelineCanvasHeight,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: Container(color: _kTrackBg),
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            top: 0,
                            child: _buildRuler(),
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            top: _kRulerHeight,
                            height: _kTrackHeight,
                            child: widget.words.isEmpty
                                ? const Align(
                                    alignment: Alignment.centerLeft,
                                    child: Padding(
                                      padding: EdgeInsets.only(left: 16),
                                      child: Text(
                                        'Tap "Generate Subtitles" below to place words on the timeline',
                                        style: TextStyle(
                                          color: Colors.white38,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                  )
                                : Stack(
                                    clipBehavior: Clip.none,
                                    children: _buildStaggeredChips(posSec),
                                  ),
                          ),
                          _buildPlayhead(posSec),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Tap word to select/jump • Hold or tap Edit • Drag to move',
                    style: TextStyle(color: Colors.white38, fontSize: 10),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter(this.totalDurationSeconds);

  final double totalDurationSeconds;

  @override
  void paint(Canvas canvas, Size size) {
    final majorPaint = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1;
    final minorPaint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 0.5;
    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    final int totalSeconds = totalDurationSeconds.ceil();
    for (int s = 0; s <= totalSeconds; s++) {
      final double x = s * _kPixelsPerSecond;
      if (x > size.width) break;

      canvas.drawLine(
        Offset(x, size.height * 0.45),
        Offset(x, size.height),
        majorPaint,
      );

      textPainter.text = TextSpan(
        text: '${s}s',
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 9,
          fontWeight: FontWeight.w600,
        ),
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(x + 3, 2));

      final double halfX = x + _kPixelsPerSecond / 2;
      if (halfX < size.width) {
        canvas.drawLine(
          Offset(halfX, size.height * 0.68),
          Offset(halfX, size.height),
          minorPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_RulerPainter oldDelegate) =>
      oldDelegate.totalDurationSeconds != totalDurationSeconds;
}

class _WordEditorDialog extends StatefulWidget {
  const _WordEditorDialog({
    required this.word,
    required this.safeDuration,
  });

  final SubtitleWord word;
  final double safeDuration;

  @override
  State<_WordEditorDialog> createState() => _WordEditorDialogState();
}

class _WordEditorDialogState extends State<_WordEditorDialog> {
  late final TextEditingController _controller;
  late double _startSec;
  late double _endSec;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.word.text);
    _startSec = widget.word.start;
    _endSec = widget.word.end;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _shift(double delta) {
    final dur = math.max(0.05, _endSec - _startSec);
    final maxStart = math.max(0.0, widget.safeDuration - dur);
    final nextStart = (_startSec + delta).clamp(0.0, maxStart);
    setState(() {
      _startSec = nextStart;
      _endSec = nextStart + dur;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Subtitle Word'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Word text',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => Navigator.pop(
              context,
              (
                action: 'save',
                text: _controller.text.trim(),
                start: _startSec,
                end: _endSec,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Timing: ${_startSec.toStringAsFixed(2)}s – ${_endSec.toStringAsFixed(2)}s',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              OutlinedButton(
                onPressed: () => _shift(-0.1),
                child: const Text('-0.1s'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => _shift(0.1),
                child: const Text('+0.1s'),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            (action: 'delete', text: '', start: _startSec, end: _endSec),
          ),
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          child: const Text('Delete'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            (
              action: 'save',
              text: _controller.text.trim(),
              start: _startSec,
              end: _endSec,
            ),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _AddWordDialog extends StatefulWidget {
  const _AddWordDialog({required this.insertAtSeconds});

  final double insertAtSeconds;

  @override
  State<_AddWordDialog> createState() => _AddWordDialogState();
}

class _AddWordDialogState extends State<_AddWordDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Subtitle Word'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Inserted at ${widget.insertAtSeconds.toStringAsFixed(2)}s',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Word',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.pop(context, v.trim()),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Add'),
        ),
      ],
    );
  }
}
