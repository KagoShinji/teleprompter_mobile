import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../core/models/subtitle_word.dart';
import '../captions/widgets/interactive_subtitle_overlay.dart';
import 'api_key_store.dart';
import 'ffmpeg_export_service.dart';
import 'gemini_subtitle_service.dart';
import 'srt_exporter.dart';
import 'widgets/subtitle_timeline_editor.dart';

class SubtitleStudioScreen extends StatefulWidget {
  const SubtitleStudioScreen({
    super.key,
    this.videoPicker,
    this.subtitleServiceBuilder,
  });

  final Future<XFile?> Function()? videoPicker;
  final GeminiSubtitleService Function()? subtitleServiceBuilder;

  @override
  State<SubtitleStudioScreen> createState() => _SubtitleStudioScreenState();
}

class _SubtitleStudioScreenState extends State<SubtitleStudioScreen> {
  XFile? _pickedVideo;
  VideoPlayerController? _player;
  List<SubtitleWord> _words = [];
  bool _loadingVideo = false;
  bool _generating = false;
  double _genProgress = 0;
  String _genStatus = '';
  int _generationRunId = 0;
  GeminiSubtitleService? _activeSubtitleService;
  bool _exporting = false;
  double _exportProgress = 0;
  String? _exportError;
  bool _exported = false;
  static const Offset _defaultPosition = Offset(0.0, 0.65);

  SubtitlePresetStyle _style = SubtitlePresetStyle.bouncyYellow;
  SubtitleFontStyle _fontStyle = SubtitleFontStyle.modern;
  double _fontSize = 22.0;
  bool _showBackground = false;
  bool _exactTimelineOnly = true;
  Offset _subtitlePosition = _defaultPosition;

  @override
  void dispose() {
    _activeSubtitleService?.cancel();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _pickVideo() async {
    if (_loadingVideo || _generating || _exporting) return;
    setState(() => _loadingVideo = true);

    try {
      final picked = await (widget.videoPicker?.call() ??
          ImagePicker().pickVideo(source: ImageSource.gallery));
      if (picked == null) {
        if (mounted) setState(() => _loadingVideo = false);
        return;
      }

      final controller = VideoPlayerController.file(File(picked.path));
      await controller.initialize();
      await controller.setLooping(true);

      if (!mounted) {
        await controller.dispose();
        return;
      }

      final oldPlayer = _player;
      setState(() {
        _pickedVideo = picked;
        _player = controller;
        _words = [];
        _exported = false;
        _exportError = null;
        _loadingVideo = false;
      });
      await oldPlayer?.dispose();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingVideo = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open video: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  Future<void> _generateSubtitles() async {
    final video = _pickedVideo;
    if (video == null || _generating) return;

    final apiKey = await ApiKeyStore.load();
    if (apiKey == null || apiKey.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Auto-subtitles are unavailable in this build. Please contact support.',
            ),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
      return;
    }

    if (!mounted) return;
    final runId = ++_generationRunId;
    final service =
        widget.subtitleServiceBuilder?.call() ?? GeminiSubtitleService();
    _activeSubtitleService = service;

    setState(() {
      _generating = true;
      _genProgress = 0.02;
      _genStatus = 'Preparing audio for fast transcription…';
      _exportError = null;
      _exported = false;
    });

    try {
      final result = await service.transcribe(
        video.path,
        apiKey,
        onStatus: (s) {
          if (mounted && runId == _generationRunId) {
            setState(() => _genStatus = s);
          }
        },
        onProgress: (p) {
          if (mounted && runId == _generationRunId) {
            setState(() => _genProgress = p);
          }
        },
      );
      if (!mounted || runId != _generationRunId) return;
      _activeSubtitleService = null;
      setState(() {
        _words = result;
        _generating = false;
        _genProgress = 0;
        _genStatus = '';
      });
      if (result.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No speech was detected in this video.'),
          ),
        );
      } else {
        // Jump to the start and begin playback so the user sees the sync.
        await _player?.seekTo(Duration.zero);
        await _player?.play();
      }
    } catch (e) {
      if (!mounted || runId != _generationRunId) return;
      _activeSubtitleService = null;
      setState(() {
        _generating = false;
        _genProgress = 0;
        _genStatus = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Subtitle generation failed: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  void _cancelGeneration() {
    if (!_generating) return;
    _generationRunId++;
    _activeSubtitleService?.cancel();
    _activeSubtitleService = null;
    setState(() {
      _generating = false;
      _genProgress = 0;
      _genStatus = '';
    });
  }

  void _onWordMoved(SubtitleWord word) {
    setState(() {
      _words.sort((a, b) => a.start.compareTo(b.start));
      _exported = false;
    });
  }

  void _onWordEdited(SubtitleWord word, String newText) {
    setState(() {
      word.text = newText;
      _exported = false;
    });
  }

  void _onWordDeleted(SubtitleWord word) {
    setState(() {
      _words.remove(word);
      _exported = false;
    });
  }

  void _onWordAdded(SubtitleWord word) {
    setState(() {
      _words.add(word);
      _words.sort((a, b) => a.start.compareTo(b.start));
      _exported = false;
    });
  }

  void _seekTo(double seconds) {
    _player?.seekTo(Duration(milliseconds: (seconds * 1000).round()));
  }

  Future<void> _exportVideo() async {
    final video = _pickedVideo;
    final player = _player;
    if (video == null || _words.isEmpty || _exporting) return;

    setState(() {
      _exporting = true;
      _exportProgress = 0;
      _exportError = null;
      _exported = false;
    });

    try {
      final tempDir = await getTemporaryDirectory();
      final srtPath = await SrtExporter.toSrtFile(
        _words,
        tempDir.path,
        exactTimelineOnly: _exactTimelineOnly,
      );
      final totalMs = player?.value.duration.inMilliseconds;
      final outputPath = await FfmpegExportService().burnSubtitles(
        video.path,
        srtPath,
        style: _style,
        fontStyle: _fontStyle,
        fontSize: _fontSize,
        showBackground: _showBackground,
        position: _subtitlePosition,
        totalDurationMs: totalMs,
        onProgress: (p) {
          if (mounted) setState(() => _exportProgress = p);
        },
      );
      await Gal.putVideo(outputPath);
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _exported = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Video exported with subtitles to gallery!'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _exportError = e.toString();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Export failed: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ─── Build helpers ────────────────────────────────────────────────────────

  Widget _buildVideoPreview() {
    final activePlayer = _player;
    final initialized = activePlayer != null && activePlayer.value.isInitialized;
    final aspect = initialized && activePlayer.value.aspectRatio > 0
        ? activePlayer.value.aspectRatio
        : 16 / 9;

    return Container(
      color: Colors.black,
      width: double.infinity,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.42,
        minHeight: 200,
      ),
      child: Center(
        child: initialized
            ? AspectRatio(
                aspectRatio: aspect,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    GestureDetector(
                      onTap: () {
                        activePlayer.value.isPlaying
                            ? activePlayer.pause()
                            : activePlayer.play();
                      },
                      child: VideoPlayer(activePlayer),
                    ),
                    if (_words.isNotEmpty)
                      InteractiveSubtitleOverlay(
                        words: _words,
                        player: activePlayer,
                        style: _style,
                        fontStyle: _fontStyle,
                        fontSize: _fontSize,
                        showBackground: _showBackground,
                        exactTimelineOnly: _exactTimelineOnly,
                        position: _subtitlePosition,
                        onPositionChanged: (next) => setState(() {
                          _subtitlePosition = next;
                          _exported = false;
                        }),
                        onBeforeEdit: () => activePlayer.pause(),
                        onWordEdited: _onWordEdited,
                      ),
                  ],
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.video_library_outlined,
                    size: 52,
                    color: Colors.white30,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _loadingVideo ? null : _pickVideo,
                    icon: _loadingVideo
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.photo_library_outlined),
                    label: Text(
                      _loadingVideo ? 'Loading video…' : 'Select Video from Gallery',
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildPlaybackControls() {
    final activePlayer = _player;
    if (activePlayer == null || !activePlayer.value.isInitialized) {
      return const SizedBox.shrink();
    }

    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: activePlayer,
      builder: (context, value, _) {
        final total = value.duration.inMilliseconds.toDouble();
        final maxVal = total > 0 ? total : 1.0;
        final pos = value.position.inMilliseconds.toDouble().clamp(0.0, maxVal);
        return Container(
          color: const Color(0xff0d0d0f),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            children: [
              IconButton(
                icon: Icon(
                  value.isPlaying ? Icons.pause_circle : Icons.play_circle,
                  color: Colors.white,
                  size: 28,
                ),
                onPressed: () {
                  value.isPlaying ? activePlayer.pause() : activePlayer.play();
                },
              ),
              Text(
                _formatDuration(value.position),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              Expanded(
                child: Slider(
                  value: pos,
                  min: 0.0,
                  max: maxVal,
                  activeColor: const Color(0xffffe500),
                  inactiveColor: Colors.white24,
                  onChanged: (v) => activePlayer.seekTo(
                    Duration(milliseconds: v.round()),
                  ),
                ),
              ),
              Text(
                _formatDuration(value.duration),
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildGenerateButton({required bool compact}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: _generating ? null : _generateSubtitles,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xffffe500),
            foregroundColor: Colors.black,
            disabledBackgroundColor: const Color(0xff2c2c32),
            disabledForegroundColor: const Color(0xffffe500),
            padding: EdgeInsets.symmetric(vertical: compact ? 10 : 14),
            textStyle: TextStyle(
              fontSize: compact ? 14 : 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          icon: _generating
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xffffe500),
                  ),
                )
              : const Icon(Icons.auto_awesome),
          label: Text(
            _generating
                ? 'Generating (${(_genProgress * 100).round()}%)…'
                : (compact ? 'Regenerate Subtitles' : 'Generate Subtitles'),
          ),
        ),
        if (_generating) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xff16161a),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _genStatus.isNotEmpty
                            ? _genStatus
                            : 'Preparing Gemini transcription…',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${(_genProgress * 100).round()}%',
                      style: const TextStyle(
                        color: Color(0xffffe500),
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _cancelGeneration,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white70,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: _genProgress.clamp(0.02, 1.0)),
                    duration: const Duration(milliseconds: 220),
                    builder: (context, animValue, _) => LinearProgressIndicator(
                      value: animValue,
                      minHeight: 8,
                      color: const Color(0xffffe500),
                      backgroundColor: Colors.white12,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Extracting and transcribing audio with Gemini.',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildStyleControls() {
    final hasMovedPosition =
        (_subtitlePosition - _defaultPosition).distance > 0.02;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              ChoiceChip(
                label: const Text('Exact Sync'),
                selected: _exactTimelineOnly,
                onSelected: (_) => setState(() {
                  _exactTimelineOnly = true;
                  _exported = false;
                }),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('4-Word Phrase'),
                selected: !_exactTimelineOnly,
                onSelected: (_) => setState(() {
                  _exactTimelineOnly = false;
                  _exported = false;
                }),
              ),
              const SizedBox(width: 8),
              for (final style in SubtitlePresetStyle.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(
                      switch (style) {
                        SubtitlePresetStyle.bouncyYellow => 'Bouncy Yellow',
                        SubtitlePresetStyle.neonCyan => 'Neon Cyan',
                        SubtitlePresetStyle.minimalDark => 'Minimal',
                      },
                    ),
                    selected: _style == style,
                    onSelected: (_) => setState(() {
                      _style = style;
                      _exported = false;
                    }),
                  ),
                ),
              FilterChip(
                label: const Text('Pill BG'),
                selected: _showBackground,
                onSelected: (v) => setState(() {
                  _showBackground = v;
                  _exported = false;
                }),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Text(
                  'Font',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
              for (final fontStyle in SubtitleFontStyle.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(
                      switch (fontStyle) {
                        SubtitleFontStyle.modern => 'Modern',
                        SubtitleFontStyle.impact => 'Bold',
                        SubtitleFontStyle.serif => 'Serif',
                        SubtitleFontStyle.mono => 'Mono',
                        SubtitleFontStyle.italic => 'Italic',
                      },
                      style: switch (fontStyle) {
                        SubtitleFontStyle.modern => const TextStyle(
                            fontWeight: FontWeight.w700,
                          ),
                        SubtitleFontStyle.impact => const TextStyle(
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.3,
                          ),
                        SubtitleFontStyle.serif => const TextStyle(
                            fontFamilyFallback: [
                              'Georgia',
                              'Times New Roman',
                              'serif',
                            ],
                          ),
                        SubtitleFontStyle.mono => const TextStyle(
                            fontFamilyFallback: ['Courier New', 'monospace'],
                          ),
                        SubtitleFontStyle.italic => const TextStyle(
                            fontStyle: FontStyle.italic,
                            fontWeight: FontWeight.w700,
                          ),
                      },
                    ),
                    selected: _fontStyle == fontStyle,
                    onSelected: (_) => setState(() {
                      _fontStyle = fontStyle;
                      _exported = false;
                    }),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            const Text(
              'Size',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            Expanded(
              child: Slider(
                value: _fontSize,
                min: 12,
                max: 48,
                divisions: 18,
                activeColor: const Color(0xffffe500),
                label: '${_fontSize.round()}px',
                onChanged: (v) => setState(() {
                  _fontSize = v;
                  _exported = false;
                }),
              ),
            ),
            Text(
              '${_fontSize.round()}px',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            if (hasMovedPosition) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() {
                  _subtitlePosition = _defaultPosition;
                  _exported = false;
                }),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xffffe500),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text(
                  'Reset Pos',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ],
        ),
        const Text(
          'Drag subtitle on video to move • Tap word on video to edit',
          style: TextStyle(color: Colors.white38, fontSize: 11),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildEditorDock() {
    final activePlayer = _player;
    if (activePlayer == null || !activePlayer.value.isInitialized) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Select any video from your gallery to automatically transcribe spoken audio into interactive bouncy subtitles.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.5),
        ),
      );
    }

    final totalSeconds = math.max(
      1.0,
      activePlayer.value.duration.inMilliseconds / 1000.0,
    );

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SubtitleTimelineEditor(
            words: _words,
            player: activePlayer,
            totalDurationSeconds: totalSeconds,
            onWordMoved: _onWordMoved,
            onWordEdited: _onWordEdited,
            onWordDeleted: _onWordDeleted,
            onWordAdded: _onWordAdded,
            onSeek: _seekTo,
          ),
          const SizedBox(height: 12),
          _buildGenerateButton(compact: _words.isNotEmpty),
          if (_words.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildStyleControls(),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _exporting ? null : _exportVideo,
              icon: Icon(
                _exported ? Icons.check_circle : Icons.save_alt_rounded,
              ),
              label: Text(
                _exporting
                    ? 'Burning Subtitles (${(_exportProgress * 100).round()}%)…'
                    : _exported
                        ? 'Saved to Gallery'
                        : 'Export Video with Subtitles',
              ),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                disabledBackgroundColor: const Color(0xff2c2c32),
                disabledForegroundColor: Colors.white70,
                padding: const EdgeInsets.symmetric(vertical: 14),
                textStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (_exporting) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: _exportProgress > 0 ? _exportProgress : null,
              ),
            ],
            if (_exportError != null) ...[
              const SizedBox(height: 6),
              Text(
                _exportError!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final darkTheme = ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: const Color(0xff0b0b0d),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xffffe500),
        onPrimary: Colors.black,
        surface: Color(0xff16161a),
        onSurface: Colors.white,
      ),
    );
    return Theme(
      data: darkTheme,
      child: Scaffold(
      backgroundColor: const Color(0xff0b0b0d),
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Subtitle Studio'),
        actions: [
          if (_pickedVideo != null)
            IconButton(
              icon: const Icon(Icons.video_library_outlined),
              tooltip: 'Select another video',
              onPressed: (_loadingVideo || _generating || _exporting)
                  ? null
                  : _pickVideo,
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildVideoPreview(),
            _buildPlaybackControls(),
            const Divider(height: 1, color: Colors.white12),
            Expanded(
              child: SingleChildScrollView(
                child: _buildEditorDock(),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}
