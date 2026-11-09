import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:cue_mobile/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class FakeCamera extends CameraPlatform {
  final errors = StreamController<CameraErrorEvent>.broadcast();
  bool denyAccess = false;
  bool started = false;
  bool stopped = false;
  bool disposed = false;
  DeviceOrientation? lockedOrientation;

  @override
  Future<List<CameraDescription>> availableCameras() async => [
    const CameraDescription(
      name: 'front',
      lensDirection: CameraLensDirection.front,
      sensorOrientation: 90,
    ),
  ];

  @override
  Future<int> createCameraWithSettings(
    CameraDescription description,
    MediaSettings settings,
  ) async {
    if (denyAccess) throw PlatformException(code: 'CameraAccessDenied');
    return 1;
  }

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(
        const CameraInitializedEvent(
          1,
          1280,
          720,
          ExposureMode.auto,
          true,
          FocusMode.auto,
          true,
        ),
      );

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => errors.stream;

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup? imageFormatGroup,
  }) async {}

  @override
  Future<void> lockCaptureOrientation(
    int cameraId,
    DeviceOrientation orientation,
  ) async {
    lockedOrientation = orientation;
  }

  @override
  Widget buildPreview(int cameraId) => const ColoredBox(color: Colors.blue);

  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) async {
    started = true;
  }

  @override
  Future<XFile> stopVideoRecording(int cameraId) async {
    stopped = true;
    return XFile('test-recording.mp4');
  }

  @override
  Future<void> dispose(int cameraId) async {
    disposed = true;
  }
}

class FakeVideo extends VideoPlayerPlatform {
  final events = StreamController<VideoEvent>();

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    events.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        size: const Size(720, 1280),
        duration: const Duration(seconds: 10),
      ),
    );
    return 1;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => events.stream;

  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> dispose(int playerId) async {}
  @override
  Widget buildView(int playerId) => const ColoredBox(color: Colors.black);
}

void main() {
  late FakeCamera camera;
  late FakeVideo video;
  late CameraPlatform previousCamera;
  late VideoPlayerPlatform previousVideo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    previousCamera = CameraPlatform.instance;
    previousVideo = VideoPlayerPlatform.instance;
    camera = FakeCamera();
    video = FakeVideo();
    CameraPlatform.instance = camera;
    VideoPlayerPlatform.instance = video;
  });

  tearDown(() {
    CameraPlatform.instance = previousCamera;
    VideoPlayerPlatform.instance = previousVideo;
    camera.errors.add(const CameraErrorEvent(1, 'closed'));
    camera.errors.close();
    video.events.close();
  });

  testWidgets('records, pauses prompt, stops and retakes', (tester) async {
    await tester.pumpWidget(const CueApp());
    await tester.pump();
    await tester.tap(find.text('Enable camera'));
    await tester.pumpAndSettle();
    expect(camera.lockedOrientation, DeviceOrientation.portraitUp);
    expect(find.text('Start recording'), findsOneWidget);

    await tester.tap(find.text('Start recording'));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(camera.started, isTrue);
    expect(find.text('Pause prompt'), findsOneWidget);
    await tester.tap(find.text('Pause prompt'));
    await tester.pump();
    expect(find.text('Resume prompt'), findsOneWidget);
    await tester.tap(find.text('Finish take'));
    await tester.pumpAndSettle();
    expect(camera.stopped, isTrue);
    expect(find.text('Share video'), findsOneWidget);
    expect(find.text('Save to gallery'), findsOneWidget);
    expect(find.text('Retake'), findsOneWidget);
    await tester.tap(find.text('Retake'));
    await tester.pumpAndSettle();
    expect(find.text('Discard this take?'), findsOneWidget);
    await tester.tap(find.text('Keep take'));
    await tester.pumpAndSettle();
    expect(find.text('Save to gallery'), findsOneWidget);
    await tester.tap(find.text('Retake'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.text('Start recording'), findsOneWidget);
  });

  testWidgets('countdown can be cancelled and stops on background', (
    tester,
  ) async {
    await tester.pumpWidget(const CueApp());
    await tester.tap(find.text('Enable camera'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start recording'));
    await tester.pump();
    expect(find.text('Starting in 3 • Cancel'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Starting in 2 • Cancel'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(camera.started, isFalse);
    await tester.tap(find.text('Starting in 2 • Cancel'));
    await tester.pump(const Duration(seconds: 3));
    expect(camera.started, isFalse);
    await tester.tap(find.text('Start recording'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 3));
    expect(camera.started, isFalse);
    expect(camera.disposed, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('back warns before leaving an unsaved take', (tester) async {
    await tester.pumpWidget(const CueApp());
    await tester.tap(find.text('Enable camera'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start recording'));
    await tester.pump();
    expect(find.text('3'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('2'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('1'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('1'), findsNothing);
    await tester.tap(find.text('Finish take'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Discard this take?'), findsOneWidget);
    await tester.tap(find.text('Keep take'));
    await tester.pumpAndSettle();
    expect(find.text('Save to gallery'), findsOneWidget);
  });

  for (final landscape in [false, true]) {
    testWidgets(
      'fullscreen recording status stays outside the ${landscape ? 'landscape' : 'portrait'} preview',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = landscape
            ? const Size(800, 400)
            : const Size(400, 800);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(const CueApp());
        if (landscape) {
          await tester.ensureVisible(find.text('Landscape'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Landscape'));
          await tester.pump();
          expect(
            tester
                .widget<ChoiceChip>(
                  find.widgetWithText(ChoiceChip, 'Landscape'),
                )
                .selected,
            isTrue,
          );
        }
        await tester.ensureVisible(find.text('Enable camera'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Enable camera'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byTooltip('Fullscreen preview'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Fullscreen preview'));
        await tester.pump();
        await tester.tap(find.text('Start recording'));
        await tester.pump(const Duration(seconds: 3));
        await tester.pump();

        final previewScroll = find.ancestor(
          of: find.text('READ ALONG'),
          matching: find.byType(SingleChildScrollView),
        );
        final status = find.textContaining('REC ');
        expect(status, findsOneWidget);
        expect(previewScroll, findsOneWidget);
        expect(
          tester.getRect(status).top,
          greaterThanOrEqualTo(tester.getRect(previewScroll).bottom),
        );
        expect(
          tester.getRect(status).bottom,
          lessThanOrEqualTo(tester.view.physicalSize.height),
        );
        await tester.tap(find.byTooltip('Fullscreen settings'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Reading speed'), findsOneWidget);
        await tester.tap(find.byTooltip('Increase text size'));
        await tester.pump();
        expect(find.text('26px'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Finish take'));
        await tester.pumpAndSettle();
        expect(status, findsNothing);
      },
    );
  }

  testWidgets('saves a take once and allows a retake', (tester) async {
    final save = Completer<void>();
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('gal'), (call) async {
          calls.add(call);
          if (call.method == 'requestAccess') return true;
          if (call.method == 'putVideo') await save.future;
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('gal'), null);
    });

    await tester.pumpWidget(const CueApp());
    await tester.tap(find.text('Enable camera'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start recording'));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.tap(find.text('Finish take'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save to gallery'));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Saving to gallery…'),
          )
          .onPressed,
      isNull,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(calls.map((call) => call.method), ['requestAccess', 'putVideo']);
    expect(calls.last.arguments['path'], 'test-recording.mp4');
    save.complete();
    await tester.pumpAndSettle();
    expect(find.text('Saved to gallery'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.text('Retake'));
    await tester.pumpAndSettle();
    expect(find.text('Start recording'), findsOneWidget);
  });

  testWidgets('shows save errors and lets the user retry', (tester) async {
    var denied = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('gal'), (call) async {
          if (call.method == 'requestAccess') return true;
          if (call.method == 'putVideo' && denied) {
            throw PlatformException(code: 'ACCESS_DENIED');
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('gal'), null);
    });

    await tester.pumpWidget(const CueApp());
    await tester.tap(find.text('Enable camera'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start recording'));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.tap(find.text('Finish take'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save to gallery'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Gallery access was denied'), findsOneWidget);
    expect(
      tester.getRect(find.textContaining('Gallery access was denied')).bottom,
      lessThanOrEqualTo(
        tester.view.physicalSize.height / tester.view.devicePixelRatio,
      ),
    );
    expect(find.text('Save to gallery'), findsOneWidget);
    denied = false;
    await tester.tap(find.text('Save to gallery'));
    await tester.pumpAndSettle();
    expect(find.text('Saved to gallery'), findsOneWidget);
  });

  for (final size in [const Size(400, 800), const Size(800, 400)]) {
    testWidgets('fullscreen save feedback fits ${size.width}x${size.height}', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final save = Completer<void>();
      var fail = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('gal'), (call) async {
            if (call.method == 'requestAccess') return true;
            if (call.method == 'putVideo') {
              if (fail) throw PlatformException(code: 'ACCESS_DENIED');
              await save.future;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('gal'), null);
      });

      await tester.pumpWidget(const CueApp());
      await tester.tap(find.text('Enable camera'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Fullscreen preview'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Fullscreen preview'));
      await tester.pump();
      await tester.tap(find.text('Start recording'));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      await tester.tap(find.text('Finish take'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save to gallery'));
      await tester.pumpAndSettle();
      final error = find.textContaining('Gallery access was denied');
      expect(error, findsOneWidget);
      expect(tester.getRect(error).bottom, lessThanOrEqualTo(size.height));
      fail = false;
      await tester.tap(find.text('Save to gallery'));
      await tester.pump();
      expect(find.text('Saving to gallery…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining('Gallery access was denied'), findsNothing);
      save.complete();
      await tester.pumpAndSettle();
      final confirmation = find.text('Saved to gallery');
      expect(confirmation, findsOneWidget);
      expect(
        tester.getRect(confirmation).bottom,
        lessThanOrEqualTo(size.height),
      );
    });
  }

  testWidgets('surfaces camera permission errors', (tester) async {
    camera.denyAccess = true;
    await tester.pumpWidget(const CueApp());
    await tester.tap(find.text('Enable camera'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Camera could not start'), findsOneWidget);
    expect(find.text('Enable camera'), findsOneWidget);
  });

  testWidgets('surfaces camera errors after initialization', (tester) async {
    await tester.pumpWidget(const CueApp());
    await tester.tap(find.text('Enable camera'));
    await tester.pumpAndSettle();
    camera.errors.add(const CameraErrorEvent(1, 'Camera disconnected'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Camera error: Camera disconnected'),
      findsOneWidget,
    );
    expect(find.text('Enable camera'), findsOneWidget);
  });

  testWidgets('backgrounding stops the take and releases the camera', (
    tester,
  ) async {
    await tester.pumpWidget(const CueApp());
    await tester.tap(find.text('Enable camera'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start recording'));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // Speech recognition gets a moment to deliver its final words.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(camera.stopped, isTrue);
    expect(camera.disposed, isTrue);
    expect(find.text('Share video'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
