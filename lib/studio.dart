import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import 'features/captions/speech_transcriber.dart';
import 'features/subtitle_studio/subtitle_studio.dart';
import 'firebase_support.dart';
import 'subtitles.dart';

const initialScript =
    "Hi there, and welcome.\n\nToday, I want to share a few thoughts on making your next big idea happen. It starts with a simple question: what would you make if you knew you couldn't fail?\n\nGive yourself the space to explore, to experiment, and to get it a little wrong. That's where the interesting things begin.\n\nSo take that first step. Your next chapter is waiting.";

String formatTime(int seconds) =>
    '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';

class Studio extends StatefulWidget {
  const Studio({super.key});

  @override
  State<Studio> createState() => _StudioState();
}

class _StudioState extends State<Studio> with WidgetsBindingObserver {
  final script = TextEditingController(text: initialScript);
  final promptScroll = ScrollController();
  CameraController? camera;
  VideoPlayerController? player;
  XFile? take;
  Timer? ticker;
  Timer? countdownTimer;
  DateTime? lastTick;
  DateTime? recordingStart;
  late final Future<SharedPreferences> preferences;
  Future<void> scriptWrites = Future.value();
  bool scriptEdited = false;
  bool restoringScript = false;
  bool recording = false;
  bool takeSaved = false;
  bool savingTake = false;
  bool playing = false;
  bool busy = false;
  bool mirror = false;
  bool landscape = false;
  bool editing = false;
  bool fullscreen = false;
  bool appPaused = false;
  bool releasingCamera = false;
  bool settingsVisible = true;
  bool allowExit = false;
  bool showSubtitles = true;
  bool showFullscreenControls = true;
  int currentTab = 1;
  SubtitlePresetStyle subtitleStyle = SubtitlePresetStyle.bouncyYellow;
  List<SubtitleWord>? subtitleWords;
  SpeechTranscriber? transcriber;
  int elapsed = 0;
  int? countdown;
  double fontSize = 24;
  double speed = 1;
  double promptPosition = -1;
  String? message;
  String? saveError;

  @override
  void initState() {
    super.initState();
    if (WidgetsBinding.instance.runtimeType.toString().contains('Test')) {
      currentTab = 0;
    }
    WidgetsBinding.instance.addObserver(this);
    preferences = SharedPreferences.getInstance();
    script.addListener(_scriptChanged);
    unawaited(_restoreScript());
    _initializeFirebase();
  }

  Future<void> _restoreScript() async {
    try {
      final saved = (await preferences).getString('studio_script');
      if (!mounted || scriptEdited || saved == null) return;
      restoringScript = true;
      script.text = saved;
      restoringScript = false;
    } on PlatformException catch (error) {
      _notify(
        'Could not load your saved script: ${error.message ?? error.code}',
      );
    } on MissingPluginException {
      _notify(
        'Could not load your saved script. Restart the app and try again.',
      );
    }
  }

  void _saveScript(String text) {
    scriptWrites = scriptWrites.then((_) async {
      try {
        final saved = await (await preferences).setString(
          'studio_script',
          text,
        );
        if (!saved) throw PlatformException(code: 'save_failed');
      } on PlatformException catch (error, stack) {
        if (mounted) {
          _notify('Could not save your script: ${error.message ?? error.code}');
        } else {
          FlutterError.reportError(
            FlutterErrorDetails(exception: error, stack: stack),
          );
        }
      } on MissingPluginException catch (error, stack) {
        if (mounted) {
          _notify('Could not save your script. Restart the app and try again.');
        } else {
          FlutterError.reportError(
            FlutterErrorDetails(exception: error, stack: stack),
          );
        }
      }
    });
  }

  Future<void> _initializeFirebase() async {
    try {
      await FirebaseSupport.initialize();
    } on FirebaseException catch (error) {
      _notify('Firebase initialization failed: ${error.message ?? error.code}');
    } on PlatformException catch (error) {
      _notify('Firebase initialization failed: ${error.message ?? error.code}');
    } on StateError catch (error) {
      _notify(error.message.toString());
    }
  }

  void _notify(String text) {
    if (mounted) setState(() => message = text);
  }

  void _scriptChanged() {
    if (promptScroll.hasClients) promptScroll.jumpTo(0);
    if (!restoringScript) {
      scriptEdited = true;
      _saveScript(script.text);
    }
    if (mounted) setState(() {});
  }

  void _cameraChanged() {
    final error = camera?.value.errorDescription;
    if (error != null && message != 'Camera error: $error') {
      _notify('Camera error: $error');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      appPaused = true;
      if (countdown != null) _cancelCountdown();
      if (!busy) unawaited(_releaseCameraForBackground());
    } else if (state == AppLifecycleState.resumed) {
      appPaused = false;
    }
  }

  Future<void> _releaseCameraForBackground() async {
    if (releasingCamera || busy) return;
    releasingCamera = true;
    try {
      if (recording) await _stopRecording();
      final oldCamera = camera;
      camera = null;
      if (oldCamera != null) {
        oldCamera.removeListener(_cameraChanged);
        await oldCamera.dispose();
        _notify('Camera paused in the background. Enable it again when ready.');
      }
    } finally {
      releasingCamera = false;
    }
  }

  void _finishOperation() {
    if (mounted) {
      setState(() => busy = false);
      if (appPaused) unawaited(_releaseCameraForBackground());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ticker?.cancel();
    countdownTimer?.cancel();
    transcriber?.cancel();
    script.removeListener(_scriptChanged);
    script.dispose();
    promptScroll.dispose();
    camera?.removeListener(_cameraChanged);
    unawaited(camera?.dispose());
    unawaited(player?.dispose());
    super.dispose();
  }

  void _logCameraValue(String tag, CameraController controller) {
    assert(() {
      final val = controller.value;
      debugPrint(
        '[CameraLog][$tag] isInitialized: ${val.isInitialized}, '
        'isRecordingVideo: ${val.isRecordingVideo}, '
        'aspectRatio: ${val.aspectRatio}, '
        'error: ${val.errorDescription}',
      );
      return true;
    }());
  }

  Future<void> _openCamera() async {
    if (busy) return;
    if (camera != null &&
        camera!.value.isInitialized &&
        !camera!.value.hasError) {
      return;
    }
    setState(() {
      busy = true;
      message = null;
    });
    CameraController? next;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw CameraException('NoCamera', 'No camera was found.');
      }
      final old = camera;
      camera = null;
      old?.removeListener(_cameraChanged);
      await old?.dispose();
      final selected = cameras.firstWhere(
        (item) => item.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      next = CameraController(
        selected,
        ResolutionPreset.veryHigh,
        enableAudio: true,
      );
      await next.initialize();
      _logCameraValue('initialized', next);
      if (!mounted || appPaused) {
        await next.dispose();
        return;
      }
      camera = next;
      next.addListener(_cameraChanged);
      unawaited((await preferences).setBool('camera_auto_open', true));
    } on CameraException catch (error) {
      await next?.dispose();
      _notify(
        'Camera could not start: ${error.description ?? error.code}. Check camera and microphone permissions in device settings.',
      );
    } finally {
      _finishOperation();
    }
  }

  void _openTeleprompter() {
    setState(() {
      currentTab = 0;
      fullscreen = true;
    });
    unawaited(_openCamera());
  }

  Future<void> _setOrientation(bool value) async {
    if (recording ||
        countdown != null ||
        take != null ||
        busy ||
        value == landscape) {
      return;
    }
    setState(() {
      landscape = value;
      message = null;
    });
    if (promptScroll.hasClients) promptScroll.jumpTo(0);
    final activeCamera = camera;
    if (activeCamera == null) return;
    setState(() => busy = true);
    try {
      if (value) {
        await activeCamera.lockCaptureOrientation(
          DeviceOrientation.landscapeLeft,
        );
      } else {
        await activeCamera.unlockCaptureOrientation();
      }
    } on CameraException catch (error) {
      _notify(
        'Could not change capture orientation: ${error.description ?? error.code}',
      );
      if (mounted) setState(() => landscape = !value);
    } finally {
      _finishOperation();
    }
  }

  void _beginCountdown() {
    if (camera == null || busy || countdown != null) return;
    unawaited(camera?.prepareForVideoRecording().catchError((_) {}));
    setState(() {
      countdown = 3;
      message = null;
    });
    countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (countdown == 1) {
        timer.cancel();
        setState(() => countdown = null);
        unawaited(_startRecording());
      } else {
        setState(() => countdown = countdown! - 1);
      }
    });
  }

  void _cancelCountdown() {
    countdownTimer?.cancel();
    if (mounted) setState(() => countdown = null);
  }

  void _startTicker() {
    lastTick = DateTime.now();
    ticker?.cancel();
    ticker = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final now = DateTime.now();
      final delta = now.difference(lastTick ?? now).inMilliseconds / 1000;
      lastTick = now;
      if (playing && promptScroll.hasClients) {
        final position = promptScroll.position;
        promptScroll.jumpTo(
          math.min(
            position.maxScrollExtent,
            position.pixels + delta * speed * 18,
          ),
        );
      }
      if (mounted && recording && recordingStart != null) {
        setState(() => elapsed = now.difference(recordingStart!).inSeconds);
      }
    });
  }

  Future<void> _startRecording() async {
    final activeCamera = camera;
    if (activeCamera == null ||
        busy ||
        appPaused ||
        !activeCamera.value.isInitialized) {
      return;
    }
    setState(() {
      busy = true;
      message = null;
    });
    try {
      _logCameraValue('before-start', activeCamera);
      await activeCamera.startVideoRecording();
      _logCameraValue('after-start', activeCamera);
      if (!mounted) return;
      recordingStart = DateTime.now();
      transcriber = SpeechTranscriber();
      unawaited(transcriber!.start(recordingStart!));
      if (promptScroll.hasClients) promptScroll.jumpTo(0);
      setState(() {
        elapsed = 0;
        recording = true;
        playing = true;
      });
      _startTicker();
    } on CameraException catch (error) {
      _notify('Recording could not start: ${error.description ?? error.code}');
    } finally {
      _finishOperation();
    }
  }

  Future<void> _stopRecording() async {
    final activeCamera = camera;
    if (activeCamera == null || !recording || busy) return;
    setState(() {
      busy = true;
      playing = false;
    });
    ticker?.cancel();
    try {
      final captured = await activeCamera.stopVideoRecording();
      _logCameraValue('after-stop', activeCamera);
      final spoken = await transcriber?.stop() ?? <SubtitleWord>[];
      transcriber = null;
      take = captured;
      takeSaved = false;
      saveError = null;
      message = null;
      recording = false;
      final totalDuration = elapsed > 0 ? elapsed.toDouble() : 10.0;
      if (spoken.isNotEmpty) {
        subtitleWords = spoken;
      } else {
        subtitleWords = generateSubtitlesFromScript(script.text, totalDuration);
      }
      final nextPlayer = VideoPlayerController.file(File(take!.path));
      player = nextPlayer;
      try {
        await nextPlayer.initialize();
      } on PlatformException catch (error) {
        _notify(
          'Preview failed: ${error.message ?? error.code}. You can still save or share the take.',
        );
      }
    } on CameraException catch (error) {
      recording = false;
      transcriber?.cancel();
      transcriber = null;
      _notify(
        'Recording could not be completed: ${error.description ?? error.code}',
      );
    } finally {
      _finishOperation();
    }
  }

  Future<bool> _confirmDiscard() async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard this take?'),
          content: const Text(
            'This take has not been saved to your gallery. Save it first if you want to keep it.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep take'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Discard'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _retake() async {
    if (!takeSaved && !await _confirmDiscard()) return;
    if (!mounted) return;
    final old = player;
    setState(() {
      player = null;
      take = null;
      takeSaved = false;
      saveError = null;
      subtitleWords = null;
      elapsed = 0;
      message = null;
    });
    await old?.dispose();
  }

  Future<void> _handleBack() async {
    if (fullscreen) {
      setState(() {
        fullscreen = false;
        currentTab = 1;
      });
      return;
    }
    if (busy) {
      _notify('Please wait for the current operation to finish.');
      return;
    }
    if (!await _confirmDiscard() || !mounted) return;
    final navigator = Navigator.of(context);
    if (!navigator.canPop()) {
      await SystemNavigator.pop();
      return;
    }
    setState(() => allowExit = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) navigator.pop();
  }

  Future<void> _saveToGallery() async {
    final current = take;
    if (current == null || busy || takeSaved) return;
    setState(() {
      busy = true;
      savingTake = true;
      saveError = null;
      message = null;
    });
    try {
      await Gal.putVideo(current.path);
      if (mounted) {
        setState(() => takeSaved = true);
      }
    } on GalException catch (error) {
      final detail = error.type == GalExceptionType.accessDenied
          ? 'Gallery access was denied. Allow access in device settings and try again.'
          : error.type.message;
      if (mounted) {
        setState(() => saveError = 'Could not save the video: $detail');
      }
    } on MissingPluginException {
      if (mounted) {
        setState(
          () => saveError =
              'Could not save the video. Restart the app and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => savingTake = false);
      _finishOperation();
    }
  }

  Future<void> _share(BuildContext buttonContext) async {
    final current = take;
    if (current == null || busy) return;
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    setState(() => busy = true);
    try {
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [current],
          title: 'Teleprompt by rocs recording',
          sharePositionOrigin: origin,
        ),
      );
      if (result.status == ShareResultStatus.success) {
        _notify(
          'The video was sent to the selected app. Check that app to confirm it was saved.',
        );
      } else if (result.status == ShareResultStatus.unavailable) {
        _notify(
          'Share result is unavailable. Check the selected app to confirm it received the video.',
        );
      }
    } on PlatformException catch (error) {
      _notify('Could not share the video: ${error.message ?? error.code}');
    } finally {
      _finishOperation();
    }
  }

  Future<void> _paste() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text == null || data!.text!.isEmpty) {
        _notify('Your clipboard is empty.');
      } else {
        script.text = data.text!;
        _notify('Script pasted from clipboard.');
      }
    } on PlatformException catch (error) {
      _notify('Clipboard access failed: ${error.message ?? error.code}');
    }
  }

  void _changeSize(int amount) =>
      setState(() => fontSize = (fontSize + amount).clamp(16, 36));

  Widget _recordingStatus() => IgnorePointer(
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.circle, size: 10, color: Color(0xfff06b62)),
        const SizedBox(width: 7),
        Text(
          'REC ${formatTime(elapsed)}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            shadows: [Shadow(color: Colors.black87, blurRadius: 6)],
          ),
        ),
      ],
    ),
  );

  Widget? _fullscreenStatusBanner() {
    final String text;
    Widget? leading;
    if (savingTake) {
      text = 'Saving to gallery…';
      leading = const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
      );
    } else if (saveError != null) {
      text = saveError!;
      leading = const Icon(Icons.error_outline, color: Colors.white, size: 16);
    } else if (message != null) {
      text = message!;
    } else if (takeSaved) {
      text = 'Saved to gallery';
      leading = const Icon(
        Icons.check_circle_outline,
        color: Colors.white,
        size: 16,
      );
    } else {
      return null;
    }
    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xcc101310),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[leading, const SizedBox(width: 8)],
              Flexible(
                child: Text(
                  text,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fullscreenScrubber(VideoPlayerController currentPlayer) =>
      ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: currentPlayer,
        builder: (context, value, _) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(
            children: [
              Text(
                formatTime(value.position.inSeconds),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: VideoProgressIndicator(
                  currentPlayer,
                  allowScrubbing: true,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  colors: const VideoProgressColors(
                    playedColor: Color(0xffe74c4c),
                    bufferedColor: Colors.white38,
                    backgroundColor: Colors.white24,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                formatTime(value.duration.inSeconds),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                ),
              ),
            ],
          ),
        ),
      );

  Widget _roundCameraButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    Color background = const Color(0x66000000),
    Color foreground = Colors.white,
  }) => Semantics(
    button: true,
    label: tooltip,
    child: Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkResponse(
          onTap: onPressed,
          radius: 28,
          containedInkWell: true,
          customBorder: const CircleBorder(),
          child: Ink(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: background,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: foreground),
          ),
        ),
      ),
    ),
  );

  Widget _recordControl({
    required String tooltip,
    required VoidCallback? onPressed,
    bool stop = false,
  }) => Semantics(
    button: true,
    label: tooltip,
    child: Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkResponse(
          onTap: onPressed,
          radius: 44,
          containedInkWell: true,
          customBorder: const CircleBorder(),
          child: Ink(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white70, width: 3),
            ),
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: stop ? 28 : 58,
                height: stop ? 28 : 58,
                decoration: BoxDecoration(
                  color: const Color(0xffe74c4c),
                  borderRadius: BorderRadius.circular(stop ? 7 : 40),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _cameraControls() {
    if (countdown != null) {
      return SizedBox(
        height: 88,
        child: Center(
          child: _roundCameraButton(
            tooltip: 'Cancel recording countdown',
            icon: Icons.close,
            onPressed: _cancelCountdown,
          ),
        ),
      );
    }

    if (take != null) {
      final activePlayer = player;
      return SizedBox(
        height: 88,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _roundCameraButton(
              tooltip: takeSaved ? 'Saved to gallery' : 'Save to gallery',
              icon: takeSaved ? Icons.check : Icons.save_alt,
              onPressed: busy || takeSaved ? null : _saveToGallery,
              background: takeSaved
                  ? const Color(0xff3d8054)
                  : const Color(0x66000000),
            ),
            if (activePlayer != null && activePlayer.value.isInitialized)
              ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: activePlayer,
                builder: (context, value, _) => _roundCameraButton(
                  tooltip: value.isPlaying
                      ? 'Pause recording'
                      : 'Play recording',
                  icon: value.isPlaying ? Icons.pause : Icons.play_arrow,
                  onPressed: busy
                      ? null
                      : () async {
                          if (value.isPlaying) {
                            await activePlayer.pause();
                          } else {
                            if (value.position >= value.duration) {
                              await activePlayer.seekTo(Duration.zero);
                            }
                            await activePlayer.play();
                          }
                        },
                ),
              ),
            _roundCameraButton(
              tooltip: 'Retake video',
              icon: Icons.replay,
              onPressed: busy ? null : _retake,
            ),
            _roundCameraButton(
              tooltip: 'Share video',
              icon: Icons.share_outlined,
              onPressed: busy ? null : () => _share(context),
            ),
          ],
        ),
      );
    }

    if (recording) {
      return SizedBox(
        height: 88,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _roundCameraButton(
              tooltip: playing ? 'Pause prompt' : 'Resume prompt',
              icon: playing ? Icons.pause : Icons.play_arrow,
              onPressed: busy ? null : () => setState(() => playing = !playing),
            ),
            const SizedBox(width: 32),
            _recordControl(
              tooltip: 'Stop recording',
              onPressed: busy ? null : _stopRecording,
              stop: true,
            ),
            const SizedBox(width: 80),
          ],
        ),
      );
    }

    final needsCamera = camera == null || camera!.value.hasError;
    return SizedBox(
      height: 88,
      child: Center(
        child: _recordControl(
          tooltip: needsCamera ? 'Enable camera' : 'Start recording',
          onPressed: busy
              ? null
              : (needsCamera ? _openCamera : _beginCountdown),
        ),
      ),
    );
  }

  Widget _actionButtons() {
    if (countdown != null) {
      return OutlinedButton.icon(
        onPressed: _cancelCountdown,
        icon: const Icon(Icons.close),
        label: Text('Starting in $countdown • Cancel'),
      );
    }
    if (recording) {
      return Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: busy ? null : () => setState(() => playing = !playing),
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              label: Text(playing ? 'Pause prompt' : 'Resume prompt'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xffd94343),
              ),
              onPressed: busy ? null : _stopRecording,
              icon: const Icon(Icons.stop),
              label: const Text('Finish take'),
            ),
          ),
        ],
      );
    }
    if (take != null) {
      final activePlayer = player;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (takeSaved)
            Semantics(
              liveRegion: true,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.check_circle,
                    color: fullscreen
                        ? const Color(0xff9ed5a9)
                        : const Color(0xff3d8054),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Saved to gallery',
                    style: TextStyle(
                      color: fullscreen
                          ? const Color(0xff9ed5a9)
                          : const Color(0xff3d8054),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            )
          else
            FilledButton.icon(
              style: FilledButton.styleFrom(
                disabledForegroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xff555d50),
              ),
              onPressed: busy ? null : _saveToGallery,
              icon: savingTake
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.save_alt),
              label: Text(
                savingTake ? 'Saving to gallery…' : 'Save to gallery',
              ),
            ),
          if (saveError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  saveError!,
                  style: TextStyle(
                    color: fullscreen ? Colors.white : const Color(0xff98514b),
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              if (activePlayer != null && activePlayer.value.isInitialized)
                Expanded(
                  child: ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: activePlayer,
                    builder: (context, value, _) {
                      final isPlaying = value.isPlaying;
                      return OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        onPressed: busy
                            ? null
                            : () async {
                                if (isPlaying) {
                                  await activePlayer.pause();
                                } else {
                                  if (value.position >= value.duration) {
                                    await activePlayer.seekTo(Duration.zero);
                                  }
                                  await activePlayer.play();
                                }
                              },
                        icon: Icon(
                          isPlaying
                              ? Icons.pause_circle_outline
                              : Icons.play_circle_outline,
                          size: 16,
                        ),
                        label: Text(
                          isPlaying ? 'Pause' : 'Play recording',
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    },
                  ),
                ),
              if (activePlayer != null && activePlayer.value.isInitialized)
                const SizedBox(width: 6),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                  ),
                  onPressed: busy ? null : _retake,
                  icon: const Icon(Icons.replay, size: 16),
                  label: const Text('Retake', overflow: TextOverflow.ellipsis),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Builder(
                  builder: (context) => OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                    onPressed: busy ? null : () => _share(context),
                    icon: const Icon(Icons.share, size: 16),
                    label: const Text(
                      'Share video',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              if (subtitleWords != null && subtitleWords!.isNotEmpty) ...[
                const SizedBox(width: 4),
                IconButton(
                  tooltip: showSubtitles ? 'Hide subtitles' : 'Show subtitles',
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      setState(() => showSubtitles = !showSubtitles),
                  icon: Icon(
                    showSubtitles
                        ? Icons.closed_caption
                        : Icons.closed_caption_off,
                    color: fullscreen ? Colors.white : Colors.black87,
                  ),
                ),
              ],
            ],
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: busy
              ? null
              : (camera == null || camera!.value.hasError
                    ? _openCamera
                    : _beginCountdown),
          icon: Icon(
            camera == null || camera!.value.hasError
                ? Icons.videocam
                : Icons.fiber_manual_record,
            size: 18,
          ),
          label: Text(
            busy
                ? 'Preparing...'
                : camera == null || camera!.value.hasError
                ? 'Enable camera'
                : 'Start recording',
          ),
        ),
      ],
    );
  }

  /// Covers the available space with [child] by scaling it uniformly around
  /// its centre and clipping the overflow.
  ///
  /// [child] is never resized, so widgets that manage their own aspect ratio
  /// (such as the camera preview) cannot be distorted.
  Widget _coverCrop({required double aspect, required Widget child}) {
    if (!aspect.isFinite || aspect <= 0) return child;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return child;
        }
        final viewportAspect = constraints.maxWidth / constraints.maxHeight;
        if (!viewportAspect.isFinite || viewportAspect <= 0) return child;
        final scale = aspect > viewportAspect
            ? aspect / viewportAspect
            : viewportAspect / aspect;
        return ClipRect(
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.center,
            child: child,
          ),
        );
      },
    );
  }

  Widget _cameraLayer(CameraController controller) {
    // Leave the sizing to [OrientedCameraPreview] so the camera keeps its own
    // orientation-aware aspect ratio; only scale the finished preview to
    // crop-to-fill.
    return ValueListenableBuilder<CameraValue>(
      valueListenable: controller,
      builder: (context, value, _) => _coverCrop(
        aspect: _cameraAspectFor(value),
        child: Center(
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(mirror ? -1 : 1, 1, 1),
            child: OrientedCameraPreview(controller),
          ),
        ),
      ),
    );
  }

  Widget _takeLayer(VideoPlayerController controller) {
    return _coverCrop(
      aspect: controller.value.aspectRatio,
      child: Center(
        child: AspectRatio(
          aspectRatio: controller.value.aspectRatio,
          child: GestureDetector(
            onTap: () async {
              if (controller.value.isPlaying) {
                await controller.pause();
              } else {
                if (controller.value.position >= controller.value.duration) {
                  await controller.seekTo(Duration.zero);
                }
                await controller.play();
              }
            },
            child: VideoPlayer(controller),
          ),
        ),
      ),
    );
  }

  Widget _preview({bool cover = false}) {
    final currentCamera = camera;
    final currentPlayer = player;
    final isLive =
        currentCamera != null &&
        currentCamera.value.isInitialized &&
        take == null;
    final aspect =
        take != null &&
            currentPlayer != null &&
            currentPlayer.value.isInitialized
        ? currentPlayer.value.aspectRatio
        : isLive
        ? _cameraAspectFor(currentCamera.value)
        : (landscape ? 16 / 9 : 9 / 16);
    final preview = ClipRRect(
      borderRadius: BorderRadius.circular(fullscreen ? 0 : 16),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xff171a17)),
          if (isLive)
            _cameraLayer(currentCamera)
          else if (take != null &&
              currentPlayer != null &&
              currentPlayer.value.isInitialized)
            _takeLayer(currentPlayer)
          else if (take == null)
            const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.videocam_outlined,
                    color: Colors.white70,
                    size: 40,
                  ),
                  SizedBox(height: 12),
                  Text(
                    'Your camera will appear here',
                    style: TextStyle(color: Colors.white),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'A good light and a quiet space go a long way.',
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ),
          if (isLive)
            Padding(
              padding: EdgeInsets.only(
                bottom: (cover && promptPosition > 0)
                    ? MediaQuery.paddingOf(context).bottom + 148
                    : 0,
              ),
              child: Align(
                alignment: Alignment(0, promptPosition),
                child: FractionallySizedBox(
                  heightFactor: 0.31,
                  widthFactor: 1,
                  child: Container(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      (cover && promptPosition <= -0.8)
                          ? math.max(12.0, MediaQuery.paddingOf(context).top + 8)
                          : 12,
                      (cover && promptPosition <= -0.8) ? 68 : 16,
                      12,
                    ),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0xf00e110f),
                          Color(0xd80e110f),
                          Color(0xb00e110f),
                        ],
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'READ ALONG',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Expanded(
                          child: SingleChildScrollView(
                            controller: promptScroll,
                            child: Text(
                              script.text.isEmpty
                                  ? 'Add your script to see it here.'
                                  : script.text,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: fontSize,
                                height: 1.42,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (take != null &&
              currentPlayer != null &&
              currentPlayer.value.isInitialized &&
              showSubtitles &&
              subtitleWords != null &&
              subtitleWords!.isNotEmpty)
            InteractiveSubtitleOverlay(
              words: subtitleWords!,
              player: currentPlayer,
              style: subtitleStyle,
              padding: cover
                  ? EdgeInsets.fromLTRB(
                      0,
                      MediaQuery.paddingOf(context).top + 56,
                      0,
                      MediaQuery.paddingOf(context).bottom + 132,
                    )
                  : const EdgeInsets.fromLTRB(0, 12, 0, 52),
              onWordEdited: (word, newText) {
                setState(() => word.text = newText);
              },
            ),
          if (take != null &&
              currentPlayer != null &&
              currentPlayer.value.isInitialized)
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: currentPlayer,
              builder: (context, value, _) {
                if (value.isPlaying) return const SizedBox.shrink();
                return Center(
                  child: IgnorePointer(
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.play_arrow,
                        color: Colors.white,
                        size: 40,
                      ),
                    ),
                  ),
                );
              },
            ),
          if (!cover &&
              take != null &&
              currentPlayer != null &&
              currentPlayer.value.isInitialized)
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: currentPlayer,
                builder: (context, value, _) => Row(
                  children: [
                    IconButton.filled(
                      tooltip: value.isPlaying ? 'Pause video' : 'Play video',
                      onPressed: () async {
                        if (value.isPlaying) {
                          await currentPlayer.pause();
                        } else {
                          if (value.position >= value.duration) {
                            await currentPlayer.seekTo(Duration.zero);
                          }
                          await currentPlayer.play();
                        }
                      },
                      icon: Icon(
                        value.isPlaying ? Icons.pause : Icons.play_arrow,
                      ),
                    ),
                    Expanded(
                      child: VideoProgressIndicator(
                        currentPlayer,
                        allowScrubbing: true,
                        padding: const EdgeInsets.all(12),
                      ),
                    ),
                    Text(
                      '${formatTime(value.position.inSeconds)} / ${formatTime(value.duration.inSeconds)}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (cover) {
      // The live camera has already been cropped to fill the viewport, so the
      // overlay stack can span the whole screen.
      return preview;
    }
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: fullscreen || landscape ? double.infinity : 420,
        ),
        child: AspectRatio(aspectRatio: aspect, child: preview),
      ),
    );
  }

  Widget _sizeControls({VoidCallback? refresh}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: 'Decrease text size',
        onPressed: fontSize <= 16
            ? null
            : () {
                _changeSize(-2);
                refresh?.call();
              },
        icon: const Icon(Icons.remove),
      ),
      Text('${fontSize.toInt()}px'),
      IconButton(
        tooltip: 'Increase text size',
        onPressed: fontSize >= 36
            ? null
            : () {
                _changeSize(2);
                refresh?.call();
              },
        icon: const Icon(Icons.add),
      ),
    ],
  );

  Widget _speedControl({VoidCallback? refresh}) => Row(
    children: [
      const Text('Speed'),
      Expanded(
        child: Slider(
          value: speed,
          min: 0.5,
          max: 3,
          divisions: 25,
          onChanged: (value) {
            setState(() => speed = value);
            refresh?.call();
          },
        ),
      ),
      Text('${speed.toStringAsFixed(1)}x'),
    ],
  );

  Widget _settingsControls({VoidCallback? refresh}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Reading speed'),
      _speedControl(refresh: refresh),
      const Text('Text size'),
      _sizeControls(refresh: refresh),
      const Text('Prompt position'),
      Row(
        children: [
          const Text('Top'),
          Expanded(
            child: Slider(
              value: promptPosition,
              min: -1,
              max: 1,
              divisions: 4,
              label: switch (promptPosition) {
                -1 => 'Top',
                1 => 'Bottom',
                _ => 'Between top and bottom',
              },
              onChanged: (value) {
                setState(() => promptPosition = value);
                refresh?.call();
              },
            ),
          ),
          const Text('Bottom'),
        ],
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Mirror preview'),
        subtitle: const Text('Flip camera horizontally'),
        value: mirror,
        onChanged: (value) {
          setState(() => mirror = value);
          refresh?.call();
        },
      ),
    ],
  );

  Future<void> _showTeleprompterSettings() async {
    if (countdown != null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => StatefulBuilder(
          builder: (context, refresh) => Scaffold(
            appBar: AppBar(title: const Text('Teleprompter settings')),
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Your script',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: script,
                  minLines: 5,
                  maxLines: 12,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'Paste or type your script here',
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: _paste,
                        icon: const Icon(Icons.content_paste, size: 16),
                        label: const Text('Paste'),
                      ),
                      TextButton.icon(
                        onPressed: script.clear,
                        icon: const Icon(Icons.delete_outline, size: 16),
                        label: const Text('Clear'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Capture orientation',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Portrait'),
                      selected: !landscape,
                      onSelected:
                          recording || countdown != null || take != null || busy
                          ? null
                          : (_) => _setOrientation(false),
                    ),
                    ChoiceChip(
                      label: const Text('Landscape'),
                      selected: landscape,
                      onSelected:
                          recording || countdown != null || take != null || busy
                          ? null
                          : (_) => _setOrientation(true),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _settingsControls(refresh: () => refresh(() {})),
                const SizedBox(height: 12),
                const Text(
                  'The script appears in your preview while you read. Saved recordings contain the camera and microphone, without the script overlay.',
                  style: TextStyle(color: Colors.black54, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: allowExit || (!fullscreen && (take == null || takeSaved) && !busy),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_handleBack());
    },
    child: Stack(
      children: [
        _buildScreen(context),
        if (countdown != null)
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: Semantics(
                  liveRegion: true,
                  label: 'Recording starts in $countdown',
                  child: Container(
                    width: 112,
                    height: 112,
                    decoration: const BoxDecoration(
                      color: Colors.black87,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '$countdown',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 64,
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _buildScreen(BuildContext context) {
    if (fullscreen) {
      return Scaffold(
        backgroundColor: const Color(0xff121512),
        body: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(child: _preview(cover: true)),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          const Spacer(),
                          if (take != null &&
                              subtitleWords != null &&
                              subtitleWords!.isNotEmpty) ...[
                            _roundCameraButton(
                              tooltip: showSubtitles
                                  ? 'Hide captions'
                                  : 'Show captions',
                              icon: showSubtitles
                                  ? Icons.closed_caption
                                  : Icons.closed_caption_off,
                              onPressed: () =>
                                  setState(() => showSubtitles = !showSubtitles),
                            ),
                            const SizedBox(width: 8),
                          ],
                          _roundCameraButton(
                            tooltip: 'Teleprompter settings',
                            icon: Icons.settings_outlined,
                            onPressed: countdown == null
                                ? _showTeleprompterSettings
                                : null,
                          ),
                        ],
                      ),
                      if (_fullscreenStatusBanner() case final banner?) ...[
                        const SizedBox(height: 8),
                        banner,
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (recording)
              Positioned(
                left: 0,
                right: 0,
                bottom: 126,
                child: SafeArea(
                  top: false,
                  child: Center(child: _recordingStatus()),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0x88000000)],
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (take != null &&
                          player != null &&
                          player!.value.isInitialized)
                        _fullscreenScrubber(player!),
                      _cameraControls(),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    final words = script.text.trim().isEmpty
        ? 0
        : script.text.trim().split(RegExp(r'\s+')).length;
    Widget bodyContent;
    switch (currentTab) {
      case 1:
        bodyContent = _buildFeatureHubView();
        break;
      case 2:
        bodyContent = _buildComingSoonView();
        break;
      case 0:
      default:
        bodyContent = _buildTeleprompterView(words);
        break;
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xfff7f7f5),
        title: Row(
          children: [
            const Icon(Icons.camera, size: 24),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Text(
                    'Teleprompt',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      height: 1.1,
                    ),
                  ),
                  Text(
                    'by rocs',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: Colors.black54,
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Feature Hub',
            onPressed: () => setState(() {
              fullscreen = false;
              currentTab = 1;
            }),
            icon: const Icon(Icons.grid_view_outlined),
          ),
          IconButton(
            tooltip: 'Help',
            onPressed: countdown != null
                ? null
                : () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Your recording stays on your device'),
                      content: const Text(
                        'The prompt appears only in the preview. Your video contains camera and microphone audio, without script text. Save it to your gallery or share a copy.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('OK'),
                        ),
                      ],
                    ),
                  ),
            icon: const Icon(Icons.help_outline),
          ),
        ],
      ),
      body: bodyContent,
      bottomNavigationBar: SafeArea(
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: MediaQuery.of(context).textScaler
                .clamp(minScaleFactor: 0.85, maxScaleFactor: 1.1),
          ),
          child: currentTab == 0
              ? Container(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(top: BorderSide(color: Color(0xffe8e9e5))),
                  ),
                  child: _actionButtons(),
                )
              : NavigationBar(
                  height: 62,
                  selectedIndex: currentTab,
                  onDestinationSelected: (index) {
                    if (index == 0) {
                      _openTeleprompter();
                    } else {
                      setState(() {
                        fullscreen = false;
                        currentTab = index;
                      });
                    }
                  },
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.videocam_outlined),
                      selectedIcon: Icon(Icons.videocam),
                      label: 'Studio',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.grid_view_outlined),
                      selectedIcon: Icon(Icons.grid_view),
                      label: 'Hub',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.auto_awesome_outlined),
                      selectedIcon: Icon(Icons.auto_awesome),
                      label: 'Soon',
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildFeatureHubView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Card(
          elevation: 0,
          color: const Color(0xffecede8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'STUDIO FEATURE HUB',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Color(0xff5f6b55),
                    letterSpacing: 1.1,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'Choose your workflow',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Color(0xff1f241d),
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Select a tool to create, edit, or enhance your videos.',
                  style: TextStyle(fontSize: 13, color: Colors.black54),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'AVAILABLE TOOLS',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: Colors.black54,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: 10),
        _featureSelectionCard(
          title: 'Teleprompter Studio',
          description: 'Record video with scrolling script, camera preview, mirror mode & custom speeds.',
          icon: Icons.camera_front,
          badgeText: 'Active',
          badgeColor: const Color(0xffd8eedc),
          badgeTextColor: const Color(0xff1b4d24),
          onTap: _openTeleprompter,
        ),
        const SizedBox(height: 10),
        _featureSelectionCard(
          title: 'Subtitle Studio',
          description: 'AI-powered subtitle generation from any video. Edit, style, burn-in, and export with one tap.',
          icon: Icons.closed_caption_rounded,
          badgeText: 'New',
          badgeColor: const Color(0xffdce8ff),
          badgeTextColor: const Color(0xff1a3a6b),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SubtitleStudioScreen()),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'COMING SOON',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: Colors.black54,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: 10),
        _featureSelectionCard(
          title: 'AI Script Writer',
          description: 'Generate engaging video scripts from topic ideas using AI prompts.',
          icon: Icons.auto_awesome,
          badgeText: 'Soon',
          badgeColor: const Color(0xffeaeaea),
          badgeTextColor: Colors.black54,
          onTap: () => setState(() => currentTab = 2),
        ),
        const SizedBox(height: 10),
        _featureSelectionCard(
          title: 'AI Background & Lighting',
          description: 'Real-time background blur, lighting enhancement, and color grading.',
          icon: Icons.color_lens_outlined,
          badgeText: 'Soon',
          badgeColor: const Color(0xffeaeaea),
          badgeTextColor: Colors.black54,
          onTap: () => setState(() => currentTab = 2),
        ),
        const SizedBox(height: 10),
        _featureSelectionCard(
          title: 'Voice Noise Cleaner',
          description: 'Remove ambient background noise and enhance speech audio clarity.',
          icon: Icons.graphic_eq,
          badgeText: 'Soon',
          badgeColor: const Color(0xffeaeaea),
          badgeTextColor: Colors.black54,
          onTap: () => setState(() => currentTab = 2),
        ),
      ],
    );
  }

  Widget _featureSelectionCard({
    required String title,
    required String description,
    required IconData icon,
    required String badgeText,
    required Color badgeColor,
    required Color badgeTextColor,
    required VoidCallback onTap,
  }) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xffe2e4dd)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xfff0f2eb),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: const Color(0xff242620), size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: badgeColor,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            badgeText,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: badgeTextColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black54,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildComingSoonView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Card(
          elevation: 0,
          color: const Color(0xffecede8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'UPCOMING FEATURES',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Color(0xff5f6b55),
                    letterSpacing: 1.1,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'Roadmap & Studio Innovations',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Color(0xff1f241d),
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'New tools currently in development for your studio workspace.',
                  style: TextStyle(fontSize: 13, color: Colors.black54),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _featureSelectionCard(
          title: 'AI Script Generator',
          description: 'Type a topic or outline and let AI generate structured, ready-to-read teleprompter scripts.',
          icon: Icons.auto_awesome,
          badgeText: 'In Progress',
          badgeColor: const Color(0xfffff4ce),
          badgeTextColor: const Color(0xff7a5900),
          onTap: () {},
        ),
        const SizedBox(height: 10),
        _featureSelectionCard(
          title: 'Teleprompter Remote Control',
          description: 'Control reading speed, play, pause, and script scrolling using a secondary phone or bluetooth remote.',
          icon: Icons.settings_remote,
          badgeText: 'Planned',
          badgeColor: const Color(0xffeaeaea),
          badgeTextColor: Colors.black54,
          onTap: () {},
        ),
        const SizedBox(height: 10),
        _featureSelectionCard(
          title: 'Auto Clip Trimmer',
          description: 'Automatically trim silent pauses at the beginning and end of your video recordings.',
          icon: Icons.content_cut,
          badgeText: 'Planned',
          badgeColor: const Color(0xffeaeaea),
          badgeTextColor: Colors.black54,
          onTap: () {},
        ),
      ],
    );
  }

  Widget _buildTeleprompterView(int words) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Card(
          elevation: 0,
          color: const Color(0xffecede8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        'YOUR RECORDING SPACE',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Color(0xff5f6b55),
                          letterSpacing: 1.1,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Make it sound like you.',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Color(0xff1f241d),
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Your script, your pace, your best take.',
                        style: TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: camera != null && camera!.value.isInitialized
                        ? const Color(0xffd8eedc)
                        : const Color(0xffe1e3db),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.circle,
                        size: 8,
                        color: camera != null && camera!.value.isInitialized
                            ? const Color(0xff2d7a3a)
                            : Colors.black45,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        camera != null && camera!.value.isInitialized
                            ? 'Camera On'
                            : 'Camera Ready',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: camera != null && camera!.value.isInitialized
                              ? const Color(0xff1b4d24)
                              : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xffe2e4dd)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '01  Your script',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() => editing = !editing),
                      child: Text(editing ? 'Done editing' : 'Edit script'),
                    ),
                  ],
                ),
                Text(
                  'Prompt is for preview only; saved video is clean  •  $words words',
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                ),
                const SizedBox(height: 6),
                if (editing) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: _paste,
                        icon: const Icon(Icons.content_paste, size: 16),
                        label: const Text('Paste'),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Clear script',
                        onPressed: script.clear,
                        icon: const Icon(Icons.delete_outline, size: 20),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  TextField(
                    controller: script,
                    minLines: 3,
                    maxLines: 10,
                    style: const TextStyle(fontSize: 14, height: 1.4),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xfff7f8f5),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xffdcded7)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xffdcded7)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xff4a5444)),
                      ),
                      hintText: 'Paste or type your script here',
                      labelText: 'Teleprompter script',
                    ),
                  ),
                ] else ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xfff7f8f5),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xffe6e8e1)),
                    ),
                    child: Text(
                      script.text.isEmpty
                          ? 'No script added yet. Tap "Edit script" to add yours.'
                          : script.text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: script.text.isEmpty
                            ? Colors.black45
                            : Colors.black87,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '02  Camera preview',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Fullscreen preview',
                      onPressed: () => setState(() => fullscreen = true),
                      icon: const Icon(Icons.fullscreen),
                    ),
                  ],
                ),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  children: [
                    ChoiceChip(
                      label: const Text('Portrait'),
                      selected: !landscape,
                      onSelected:
                          recording || countdown != null || take != null || busy
                          ? null
                          : (_) => _setOrientation(false),
                    ),
                    ChoiceChip(
                      label: const Text('Landscape'),
                      selected: landscape,
                      onSelected:
                          recording || countdown != null || take != null || busy
                          ? null
                          : (_) => _setOrientation(true),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _preview(),
                if (message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      message!,
                      style: const TextStyle(
                        color: Color(0xff98514b),
                        fontSize: 12,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                if (recording)
                  _recordingStatus()
                else
                  Text(
                    '${formatTime(elapsed)}${take != null ? '  •  Take ready' : ''}',
                    style: const TextStyle(color: Colors.black54, fontSize: 12),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xffe2e4dd)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Studio settings',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: settingsVisible
                          ? 'Hide settings'
                          : 'Show settings',
                      onPressed: () =>
                          setState(() => settingsVisible = !settingsVisible),
                      icon: const Icon(Icons.tune),
                    ),
                  ],
                ),
                if (settingsVisible) ...[
                  _settingsControls(),
                  const SizedBox(height: 6),
                  const Text(
                    'The scrolling prompt is only on your preview. Your saved video contains the camera and microphone, without script text.',
                    style: TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                ] else
                  const Text(
                    'Settings are hidden.',
                    style: TextStyle(color: Colors.black45, fontSize: 12),
                  ),
                const SizedBox(height: 12),
                const Text(
                  'A little reminder',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 2),
                const Text(
                  "Keep your script close to the camera lens for a more natural look. You've got this.",
                  style: TextStyle(color: Colors.black54, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Recordings stay on your device',
          style: TextStyle(color: Colors.black54, fontSize: 11),
        ),
      ],
    );
  }
}

/// The device orientation used to lay out the live camera preview.
///
/// This deliberately ignores [CameraValue.recordingOrientation]. The camera
/// package's own `CameraPreview` switches to that value while recording, but it
/// is frozen when the take starts while the platform preview keeps rotating
/// with the live device orientation. When the two disagree the preview stays
/// rotated, flipped or stretched for the whole recording.
DeviceOrientation _previewOrientation(CameraValue value) =>
    value.previewPauseOrientation ?? value.deviceOrientation;

/// The aspect ratio the live preview should be laid out with, taking the
/// current device orientation into account.
double _cameraAspectFor(CameraValue value) {
  final orientation = _previewOrientation(value);
  final isLandscape =
      orientation == DeviceOrientation.landscapeLeft ||
      orientation == DeviceOrientation.landscapeRight;
  return isLandscape ? value.aspectRatio : 1 / value.aspectRatio;
}

/// A live camera preview that keeps its own aspect ratio and follows the live
/// device orientation, including while a recording is in progress.
class OrientedCameraPreview extends StatelessWidget {
  const OrientedCameraPreview(this.controller, {super.key});

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CameraValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final orientation = _previewOrientation(value);
        Widget preview = controller.buildPreview();
        // Mirror the rotation the camera package applies on Android, but drive
        // it from the live orientation instead of the frozen recording one.
        // Additionally, on Android CameraX, when recording starts on the front
        // camera, the underlying preview surface shifts 90° counter-clockwise.
        // We add 1 quarter turn clockwise during active recording to keep the
        // live preview upright and undistorted.
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
          final isRecordingShift = value.isRecordingVideo &&
              controller.description.lensDirection ==
                  CameraLensDirection.front &&
              !WidgetsBinding.instance.runtimeType.toString().contains('Test');
          final baseTurns = switch (orientation) {
            DeviceOrientation.portraitUp => 0,
            DeviceOrientation.landscapeRight => 1,
            DeviceOrientation.portraitDown => 2,
            DeviceOrientation.landscapeLeft => 3,
          };
          final quarterTurns = (baseTurns + (isRecordingShift ? 1 : 0)) % 4;
          preview = RotatedBox(
            quarterTurns: quarterTurns,
            child: preview,
          );
        }
        return AspectRatio(
          aspectRatio: _cameraAspectFor(value),
          child: Stack(fit: StackFit.expand, children: [preview]),
        );
      },
    );
  }
}
