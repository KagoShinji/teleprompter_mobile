import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:cue_mobile/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
    expect(find.text('Retake'), findsOneWidget);
    await tester.tap(find.text('Retake'));
    await tester.pumpAndSettle();
    expect(find.text('Start recording'), findsOneWidget);
  });

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
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(camera.stopped, isTrue);
    expect(camera.disposed, isTrue);
    expect(find.text('Share video'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
