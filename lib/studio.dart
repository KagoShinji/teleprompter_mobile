import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import 'firebase_support.dart';

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
  bool practicing = false;
  bool takeSaved = false;
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
  int elapsed = 0;
  int? countdown;
  double fontSize = 24;
  double speed = 1;
  double promptPosition = -1;
  String? message;

  @override
  void initState() {
    super.initState();
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
      if (practicing) _stopPractice();
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
    script.removeListener(_scriptChanged);
    script.dispose();
    promptScroll.dispose();
    camera?.removeListener(_cameraChanged);
    unawaited(camera?.dispose());
    unawaited(player?.dispose());
    super.dispose();
  }

  Future<void> _openCamera() async {
    if (busy) return;
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
        ResolutionPreset.high,
        enableAudio: true,
      );
      await next.initialize();
      await next.lockCaptureOrientation(
        landscape
            ? DeviceOrientation.landscapeLeft
            : DeviceOrientation.portraitUp,
      );
      if (!mounted || appPaused) {
        await next.dispose();
        return;
      }
      camera = next;
      next.addListener(_cameraChanged);
    } on CameraException catch (error) {
      await next?.dispose();
      _notify(
        'Camera could not start: ${error.description ?? error.code}. Check camera and microphone permissions in device settings.',
      );
    } finally {
      _finishOperation();
    }
  }

  Future<void> _setOrientation(bool value) async {
    if (recording ||
        practicing ||
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
      await activeCamera.lockCaptureOrientation(
        value ? DeviceOrientation.landscapeLeft : DeviceOrientation.portraitUp,
      );
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
    if (camera == null || busy || practicing || countdown != null) return;
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

  void _startPractice() {
    if (busy || recording || countdown != null || take != null) return;
    if (promptScroll.hasClients) promptScroll.jumpTo(0);
    setState(() {
      practicing = true;
      playing = true;
      message = null;
    });
    _startTicker();
  }

  void _stopPractice() {
    ticker?.cancel();
    if (mounted) {
      setState(() {
        practicing = false;
        playing = false;
      });
    }
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
      await activeCamera.startVideoRecording();
      if (!mounted) return;
      recordingStart = DateTime.now();
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
      take = captured;
      takeSaved = false;
      recording = false;
      _notify('Take ready. Save it to your gallery before closing the app.');
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
      elapsed = 0;
      message = null;
    });
    await old?.dispose();
  }

  Future<void> _handleBack() async {
    if (fullscreen) {
      setState(() => fullscreen = false);
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
      message = null;
    });
    try {
      await Gal.putVideo(current.path);
      if (mounted) {
        setState(() => takeSaved = true);
        _notify('Video saved to your gallery or Photos.');
      }
    } on GalException catch (error) {
      final detail = error.type == GalExceptionType.accessDenied
          ? 'Gallery access was denied. Allow access in device settings and try again.'
          : error.type.message;
      _notify('Could not save the video: $detail');
    } on MissingPluginException {
      _notify('Could not save the video. Restart the app and try again.');
    } finally {
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
          title: 'Cue recording',
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

  Widget _recordingStatus() => Chip(
    backgroundColor: Colors.black54,
    label: Text(
      'REC ${formatTime(elapsed)}',
      style: const TextStyle(color: Colors.white),
    ),
    avatar: const Icon(Icons.circle, size: 10, color: Color(0xfff06b62)),
  );

  Widget _actionButtons() {
    if (countdown != null) {
      return OutlinedButton.icon(
        onPressed: _cancelCountdown,
        icon: const Icon(Icons.close),
        label: Text('Starting in $countdown • Cancel'),
      );
    }
    if (practicing) {
      return Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => setState(() => playing = !playing),
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              label: Text(playing ? 'Pause prompt' : 'Resume prompt'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.icon(
              onPressed: _stopPractice,
              icon: const Icon(Icons.stop),
              label: const Text('End practice'),
            ),
          ),
        ],
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
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: busy || takeSaved ? null : _saveToGallery,
            icon: Icon(takeSaved ? Icons.check : Icons.save_alt),
            label: Text(takeSaved ? 'Saved to gallery' : 'Save to gallery'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : _retake,
                  icon: const Icon(Icons.replay),
                  label: const Text('Retake'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Builder(
                  builder: (context) => OutlinedButton.icon(
                    onPressed: busy ? null : () => _share(context),
                    icon: const Icon(Icons.share),
                    label: const Text('Share video'),
                  ),
                ),
              ),
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
        OutlinedButton.icon(
          onPressed: busy ? null : _startPractice,
          icon: const Icon(Icons.menu_book),
          label: const Text('Practice without recording'),
        ),
      ],
    );
  }

  Widget _preview() {
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
        ? (landscape
              ? currentCamera.value.aspectRatio
              : 1 / currentCamera.value.aspectRatio)
        : (landscape ? 16 / 9 : 9 / 16);
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: fullscreen || landscape ? double.infinity : 420,
        ),
        child: AspectRatio(
          aspectRatio: aspect,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(fullscreen ? 0 : 16),
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Color(0xff171a17)),
                if (isLive)
                  Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.diagonal3Values(mirror ? -1 : 1, 1, 1),
                    child: CameraPreview(currentCamera),
                  )
                else if (take != null &&
                    currentPlayer != null &&
                    currentPlayer.value.isInitialized)
                  VideoPlayer(currentPlayer)
                else if (take == null && !practicing)
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
                if (isLive || practicing)
                  Align(
                    alignment: Alignment(0, promptPosition),
                    child: FractionallySizedBox(
                      heightFactor: 0.31,
                      widthFactor: 1,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Color(0xe80e110f),
                              Color(0xc20e110f),
                              Color(0x000e110f),
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
                if (take != null &&
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
                            tooltip: value.isPlaying
                                ? 'Pause video'
                                : 'Play video',
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
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
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

  void _showFullscreenSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Studio settings',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  _settingsControls(refresh: () => setSheetState(() {})),
                ],
              ),
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
    child: _buildScreen(context),
  );

  Widget _buildScreen(BuildContext context) {
    if (fullscreen) {
      return Scaffold(
        backgroundColor: const Color(0xff171a17),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Center(child: SingleChildScrollView(child: _preview())),
              ),
              Row(
                children: [
                  const SizedBox(width: 12),
                  if (recording) _recordingStatus(),
                  if (practicing)
                    const Text(
                      'Practice',
                      style: TextStyle(color: Colors.white),
                    ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Fullscreen settings',
                    color: Colors.white,
                    onPressed: _showFullscreenSettings,
                    icon: const Icon(Icons.tune),
                  ),
                  IconButton(
                    tooltip: 'Exit fullscreen preview',
                    color: Colors.white,
                    onPressed: () => setState(() => fullscreen = false),
                    icon: const Icon(Icons.fullscreen_exit),
                  ),
                ],
              ),
              if (message != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    message!,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: _actionButtons(),
              ),
            ],
          ),
        ),
      );
    }
    final words = script.text.trim().isEmpty
        ? 0
        : script.text.trim().split(RegExp(r'\s+')).length;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xfff7f7f5),
        title: const Row(
          children: [
            Icon(Icons.camera, size: 24),
            SizedBox(width: 8),
            Text('cue.', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Help',
            onPressed: () => showDialog<void>(
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
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          const Text(
            'YOUR RECORDING SPACE',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: Color(0xff78836e),
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Make it sound like you.',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
          ),
          const Text(
            'Your script, your pace, your best take.',
            style: TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '01  Your script',
                          style: TextStyle(fontWeight: FontWeight.bold),
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
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  if (editing) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton.icon(
                          onPressed: _paste,
                          icon: const Icon(Icons.content_paste),
                          label: const Text('Paste'),
                        ),
                        IconButton(
                          tooltip: 'Clear script',
                          onPressed: script.clear,
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                    TextField(
                      controller: script,
                      minLines: 4,
                      maxLines: 12,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'Paste or type your script here',
                        labelText: 'Teleprompter script',
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '02  Camera preview',
                          style: TextStyle(fontWeight: FontWeight.bold),
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
                            recording ||
                                practicing ||
                                countdown != null ||
                                take != null ||
                                busy
                            ? null
                            : (_) => _setOrientation(false),
                      ),
                      ChoiceChip(
                        label: const Text('Landscape'),
                        selected: landscape,
                        onSelected:
                            recording ||
                                practicing ||
                                countdown != null ||
                                take != null ||
                                busy
                            ? null
                            : (_) => _setOrientation(true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
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
                      style: const TextStyle(color: Colors.black54),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Studio settings',
                          style: TextStyle(fontWeight: FontWeight.bold),
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
                    const Text(
                      'The scrolling prompt is only on your preview. Your saved video contains the camera and microphone, without script text.',
                      style: TextStyle(color: Colors.black54, fontSize: 12),
                    ),
                  ] else
                    const Text('Settings are hidden.'),
                  const SizedBox(height: 16),
                  const Text(
                    'A little reminder',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
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
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Color(0xffe8e9e5))),
          ),
          child: _actionButtons(),
        ),
      ),
    );
  }
}
