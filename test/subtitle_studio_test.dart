import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cue_mobile/core/models/subtitle_word.dart';
import 'package:cue_mobile/features/captions/widgets/interactive_subtitle_overlay.dart';
import 'package:cue_mobile/features/subtitle_studio/api_key_store.dart';
import 'package:cue_mobile/features/subtitle_studio/audio_speech_aligner.dart';
import 'package:cue_mobile/features/subtitle_studio/gemini_subtitle_service.dart';
import 'package:cue_mobile/features/subtitle_studio/srt_exporter.dart';
import 'package:cue_mobile/features/subtitle_studio/subtitle_studio_screen.dart';
import 'package:cue_mobile/features/subtitle_studio/widgets/subtitle_timeline_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _FakeVideoPlatform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _streams = {};
  int _nextId = 1;
  Duration _position = Duration.zero;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextId++;
    final controller = StreamController<VideoEvent>();
    controller.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        size: const Size(1080, 1920),
        duration: const Duration(seconds: 12),
      ),
    );
    _streams[id] = controller;
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) =>
      _streams[playerId]?.stream ?? const Stream.empty();

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<Duration> getPosition(int playerId) async => _position;

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    _position = position;
  }

  @override
  Future<void> dispose(int playerId) async {
    final controller = _streams.remove(playerId);
    if (controller != null) {
      unawaited(controller.close());
    }
  }

  @override
  Widget buildView(int playerId) => const ColoredBox(color: Colors.black87);

  void close() {
    for (final c in _streams.values) {
      c.close();
    }
    _streams.clear();
  }
}

void main() {
  late _FakeVideoPlatform fakeVideo;
  late VideoPlayerPlatform previousVideoPlatform;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    previousVideoPlatform = VideoPlayerPlatform.instance;
    fakeVideo = _FakeVideoPlatform();
    VideoPlayerPlatform.instance = fakeVideo;
    tempDir = await Directory.systemTemp.createTemp('subtitle_studio_test_');
  });

  tearDown(() async {
    VideoPlayerPlatform.instance = previousVideoPlatform;
    fakeVideo.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('ApiKeyStore', () {
    test('saves, loads, and clears API key', () async {
      expect(await ApiKeyStore.load(), isNull);
      await ApiKeyStore.save('  AQ.Ab8RN6TestKey  ');
      expect(await ApiKeyStore.load(), 'AQ.Ab8RN6TestKey');
      await ApiKeyStore.clear();
      expect(await ApiKeyStore.load(), isNull);
    });

    test('falls back to debug native channel when no pref or define is set',
        () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('cue_mobile/dev_config');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getDevGeminiApiKey') {
          return '  AQ.NativeDebugKey  ';
        }
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      expect(await ApiKeyStore.load(), 'AQ.NativeDebugKey');
    });
  });

  group('SrtExporter', () {
    test('chunks words in groups of up to 4 and writes valid SRT', () async {
      final words = [
        SubtitleWord(text: 'Hello', start: 0.5, end: 0.9),
        SubtitleWord(text: 'world', start: 0.95, end: 1.3),
        SubtitleWord(text: 'this', start: 1.35, end: 1.6),
        SubtitleWord(text: 'is', start: 1.65, end: 1.9),
        SubtitleWord(text: 'great', start: 2.1, end: 2.6),
      ];

      final srtPath = await SrtExporter.toSrtFile(words, tempDir.path);
      final content = await File(srtPath).readAsString();

      expect(content, contains('1\n00:00:00,500 --> 00:00:01,900\nHello world this is'));
      expect(content, contains('2\n00:00:02,100 --> 00:00:02,600\ngreat'));
    });

    test('exactTimelineOnly exports each word strictly in its timeline window',
        () async {
      final words = [
        SubtitleWord(text: 'Hello', start: 0.5, end: 0.9),
        SubtitleWord(text: 'Later', start: 2.5, end: 3.1),
      ];

      final srtPath = await SrtExporter.toSrtFile(
        words,
        tempDir.path,
        exactTimelineOnly: true,
      );
      final content = await File(srtPath).readAsString();

      expect(content, contains('1\n00:00:00,500 --> 00:00:00,900\nHello'));
      expect(content, contains('2\n00:00:02,500 --> 00:00:03,100\nLater'));
    });

    test('throws when words list is empty', () async {
      expect(
        () => SrtExporter.toSrtFile([], tempDir.path),
        throwsException,
      );
    });
  });

  group('GeminiSubtitleService', () {
    test('uploads via resumable protocol, polls ACTIVE, falls back model, and parses words', () async {
      final videoFile = File('${tempDir.path}/sample.mp4')
        ..writeAsBytesSync([0, 1, 2, 3, 4]);

      final requests = <String>[];
      var pollCount = 0;

      final mockClient = MockClient((request) async {
        requests.add('${request.method} ${request.url.path}');

        // Step 2: upload bytes (must match before Step 1 since path is identical)
        if (request.method == 'POST' &&
            request.url.queryParameters['upload_id'] == 'abc123') {
          expect(request.headers['X-Goog-Upload-Command'], 'upload, finalize');
          expect(request.bodyBytes, [0, 1, 2, 3, 4]);
          return http.Response(
            jsonEncode({
              'file': {
                'name': 'files/testfile123',
                'uri': 'https://generativelanguage.googleapis.com/v1beta/files/testfile123',
              },
            }),
            200,
          );
        }

        // Step 1: start resumable upload
        if (request.method == 'POST' &&
            request.url.path == '/upload/v1beta/files') {
          expect(request.headers['x-goog-api-key'], 'AQ.test-key');
          expect(request.headers['X-Goog-Upload-Protocol'], 'resumable');
          expect(request.headers['X-Goog-Upload-Command'], 'start');
          return http.Response(
            '',
            200,
            headers: {
              'x-goog-upload-url':
                  'https://generativelanguage.googleapis.com/upload/v1beta/files?upload_id=abc123',
            },
          );
        }

        // Step 3: poll status
        if (request.method == 'GET' &&
            request.url.path == '/v1beta/files/testfile123') {
          expect(request.headers['x-goog-api-key'], 'AQ.test-key');
          pollCount++;
          return http.Response(
            jsonEncode({'state': pollCount == 1 ? 'PROCESSING' : 'ACTIVE'}),
            200,
          );
        }

        // Step 4: generateContent (503 on 3.1-flash-lite -> 200 on 3.5-flash-lite)
        if (request.method == 'POST' &&
            request.url.path ==
                '/v1beta/models/gemini-3.1-flash-lite:generateContent') {
          final bodyMap = jsonDecode(request.body) as Map<String, dynamic>;
          final genCfg = bodyMap['generationConfig'] as Map<String, dynamic>;
          expect(
            (genCfg['thinkingConfig'] as Map<String, dynamic>)['thinkingLevel'],
            'low',
          );
          return http.Response('{"error":{"message":"high demand"}}', 503);
        }

        if (request.method == 'POST' &&
            request.url.path ==
                '/v1beta/models/gemini-3.5-flash-lite:generateContent') {
          expect(request.headers['x-goog-api-key'], 'AQ.test-key');
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {
                        'text': jsonEncode([
                          {'word': 'world', 'start': '00:00.900', 'end': '00:01.200'},
                          {'word': 'hello', 'start': '00:00.400', 'end': '00:00.800'},
                        ]),
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }

        // Step 5: cleanup DELETE
        if (request.method == 'DELETE' &&
            request.url.path == '/v1beta/files/testfile123') {
          return http.Response('{}', 200);
        }

        return http.Response('unexpected: ${request.method} ${request.url}', 500);
      });

      final service = GeminiSubtitleService(client: mockClient);
      final statuses = <String>[];
      final progressValues = <double>[];
      final words = await service.transcribe(
        videoFile.path,
        'AQ.test-key',
        onStatus: statuses.add,
        onProgress: progressValues.add,
        pollInterval: Duration.zero,
      );

      expect(words.map((w) => w.text), ['hello', 'world']);
      expect(words.first.start, 0.4);
      expect(words.first.end, 0.8);
      expect(words.last.start, 0.9);
      expect(pollCount, 2);
      expect(statuses, isNotEmpty);
      expect(progressValues, isNotEmpty);
      expect(progressValues.first, lessThan(0.5));
      expect(progressValues.last, 1.0);
      for (var i = 1; i < progressValues.length; i++) {
        expect(progressValues[i], greaterThanOrEqualTo(progressValues[i - 1]));
      }
      expect(
        requests,
        contains('POST /v1beta/models/gemini-3.5-flash-lite:generateContent'),
      );
    });

    test('uploads extracted audio-only track when available and cleans temp file',
        () async {
      final videoFile = File('${tempDir.path}/big_video.mp4')
        ..writeAsBytesSync([9, 9, 9, 9, 9, 9]);
      final audioFile = File('${tempDir.path}/tiny_audio.m4a')
        ..writeAsBytesSync([1, 2]);
      String? uploadedMime;

      final mockClient = MockClient((request) async {
        if (request.method == 'POST' &&
            request.url.queryParameters['upload_id'] == 'aud1') {
          expect(request.bodyBytes, [1, 2]);
          return http.Response(
            jsonEncode({
              'file': {
                'name': 'files/audfile',
                'uri': 'https://generativelanguage.googleapis.com/v1beta/files/audfile',
              },
            }),
            200,
          );
        }
        if (request.method == 'POST' &&
            request.url.path == '/upload/v1beta/files') {
          uploadedMime = request.headers['X-Goog-Upload-Header-Content-Type'];
          return http.Response(
            '',
            200,
            headers: {
              'x-goog-upload-url':
                  'https://generativelanguage.googleapis.com/upload/v1beta/files?upload_id=aud1',
            },
          );
        }
        if (request.method == 'GET' &&
            request.url.path == '/v1beta/files/audfile') {
          return http.Response(jsonEncode({'state': 'ACTIVE'}), 200);
        }
        if (request.method == 'POST' &&
            request.url.path ==
                '/v1beta/models/gemini-3.1-flash-lite:generateContent') {
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {
                        'text': jsonEncode([
                          {'word': 'fast', 'start_ms': 100, 'end_ms': 400},
                        ]),
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }
        if (request.method == 'DELETE') {
          return http.Response('{}', 200);
        }
        return http.Response('unexpected', 500);
      });

      final service = GeminiSubtitleService(
        client: mockClient,
        audioExtractor: (_) async => audioFile,
      );
      final words = await service.transcribe(
        videoFile.path,
        'AQ.test-key',
        pollInterval: Duration.zero,
      );

      expect(uploadedMime, 'audio/mp4');
      expect(words.map((w) => w.text), ['fast']);
      expect(audioFile.existsSync(), isFalse);
    });

    test('falls back to backup model when primary model times out', () async {
      final videoFile = File('${tempDir.path}/timeout.mp4')
        ..writeAsBytesSync([0, 1, 2]);
      final requests = <String>[];

      final mockClient = MockClient((request) async {
        requests.add('${request.method} ${request.url.path}');
        if (request.method == 'POST' &&
            request.url.queryParameters['upload_id'] == 't1') {
          return http.Response(
            jsonEncode({
              'file': {
                'name': 'files/tfile',
                'uri': 'https://generativelanguage.googleapis.com/v1beta/files/tfile',
              },
            }),
            200,
          );
        }
        if (request.method == 'POST' &&
            request.url.path == '/upload/v1beta/files') {
          return http.Response(
            '',
            200,
            headers: {
              'x-goog-upload-url':
                  'https://generativelanguage.googleapis.com/upload/v1beta/files?upload_id=t1',
            },
          );
        }
        if (request.method == 'GET') {
          return http.Response(jsonEncode({'state': 'ACTIVE'}), 200);
        }
        if (request.method == 'POST' &&
            request.url.path ==
                '/v1beta/models/gemini-3.1-flash-lite:generateContent') {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          return http.Response('{}', 200);
        }
        if (request.method == 'POST' &&
            request.url.path ==
                '/v1beta/models/gemini-3.5-flash-lite:generateContent') {
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {
                        'text': jsonEncode([
                          {'word': 'recovered', 'start': '00:01.250', 'end': '00:01.700'},
                        ]),
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      });

      final service = GeminiSubtitleService(
        client: mockClient,
        audioExtractor: (_) async => null,
      );
      final words = await service.transcribe(
        videoFile.path,
        'AQ.test-key',
        pollInterval: Duration.zero,
        requestTimeout: const Duration(milliseconds: 40),
      );

      expect(words.map((w) => w.text), ['recovered']);
      expect(words.single.start, 1.25);
      expect(words.single.end, 1.7);
      expect(
        requests,
        contains('POST /v1beta/models/gemini-3.5-flash-lite:generateContent'),
      );
    });
  });

  group('AudioSpeechAligner', () {
    File writeTestWav({
      required int sampleRate,
      required Int16List samples,
      bool includeListChunk = false,
    }) {
      final listChunk = includeListChunk ? <int>[...'LIST'.codeUnits, 4, 0, 0, 0, 1, 2, 3, 4] : <int>[];
      final dataLen = samples.length * 2;
      final fmtLen = 16;
      final riffSize = 4 + (8 + fmtLen) + listChunk.length + (8 + dataLen);
      final out = BytesBuilder();
      out.add('RIFF'.codeUnits);
      out.add((ByteData(4)..setUint32(0, riffSize, Endian.little)).buffer.asUint8List());
      out.add('WAVE'.codeUnits);
      out.add('fmt '.codeUnits);
      out.add((ByteData(4)..setUint32(0, fmtLen, Endian.little)).buffer.asUint8List());
      final fmtBody = ByteData(16)
        ..setUint16(0, 1, Endian.little)
        ..setUint16(2, 1, Endian.little)
        ..setUint32(4, sampleRate, Endian.little)
        ..setUint32(8, sampleRate * 2, Endian.little)
        ..setUint16(12, 2, Endian.little)
        ..setUint16(14, 16, Endian.little);
      out.add(fmtBody.buffer.asUint8List());
      if (listChunk.isNotEmpty) out.add(listChunk);
      out.add('data'.codeUnits);
      out.add((ByteData(4)..setUint32(0, dataLen, Endian.little)).buffer.asUint8List());
      final pcmBytes = ByteData(dataLen);
      for (int i = 0; i < samples.length; i++) {
        pcmBytes.setInt16(i * 2, samples[i], Endian.little);
      }
      out.add(pcmBytes.buffer.asUint8List());
      final file = File('${tempDir.path}/align_probe_${includeListChunk ? 1 : 0}.wav')
        ..writeAsBytesSync(out.toBytes());
      return file;
    }

    test('detects true speech segments across RIFF chunks and aligns drifted words', () {
      const sampleRate = 8000;
      const totalSec = 8;
      final samples = Int16List(sampleRate * totalSec);
      // Burst 1: 1.60s .. 2.40s
      for (int i = (1.6 * sampleRate).round(); i < (2.4 * sampleRate).round(); i++) {
        samples[i] = i.isEven ? 9000 : -9000;
      }
      // Burst 2: 5.80s .. 7.35s
      for (int i = (5.8 * sampleRate).round(); i < (7.35 * sampleRate).round(); i++) {
        samples[i] = i.isEven ? 8500 : -8500;
      }

      final wavFile = writeTestWav(
        sampleRate: sampleRate,
        samples: samples,
        includeListChunk: true,
      );
      final segments = AudioSpeechAligner.detectSpeechSegmentsFromWav(wavFile);
      expect(segments.length, 2);
      expect(segments[0].start, closeTo(1.6, 0.05));
      expect(segments[0].end, closeTo(2.4, 0.05));
      expect(segments[1].start, closeTo(5.8, 0.05));
      expect(segments[1].end, closeTo(7.35, 0.05));

      final drifted = [
        SubtitleWord(text: 'Hello', start: 0.0, end: 1.1),
        SubtitleWord(text: 'world.', start: 1.1, end: 2.32),
        SubtitleWord(text: 'Testing', start: 3.84, end: 4.72),
        SubtitleWord(text: 'timing.', start: 4.72, end: 6.4),
      ];
      final aligned = AudioSpeechAligner.alignWordsToSegments(drifted, segments);
      expect(aligned[0].start, closeTo(1.6, 0.05));
      expect(aligned[1].end, closeTo(2.4, 0.05));
      expect(aligned[2].start, closeTo(5.8, 0.05));
      expect(aligned[3].end, closeTo(7.35, 0.05));

      // Already accurate words (< 0.18s drift) remain untouched.
      final accurate = [
        SubtitleWord(text: 'Hello', start: 1.56, end: 1.89),
        SubtitleWord(text: 'world.', start: 1.95, end: 2.33),
        SubtitleWord(text: 'Testing', start: 5.86, end: 6.27),
        SubtitleWord(text: 'timing.', start: 6.33, end: 7.25),
      ];
      final preserved = AudioSpeechAligner.alignWordsToSegments(accurate, segments);
      expect(preserved[0].start, 1.56);
      expect(preserved[2].start, 5.86);
    });

    test('skips segmentation on constant loud audio without silence gaps', () {
      const sampleRate = 8000;
      final samples = Int16List(sampleRate * 4);
      for (int i = 0; i < samples.length; i++) {
        samples[i] = i.isEven ? 6000 : -6000;
      }
      final segments = AudioSpeechAligner.detectSpeechSegments(samples, sampleRate);
      expect(segments, isEmpty);
    });
  });

  group('InteractiveSubtitleOverlay', () {
    testWidgets('shows current chunk, bounces active word, and allows tap edit',
        (tester) async {
      final controller = VideoPlayerController.file(
        File('${tempDir.path}/dummy.mp4'),
      );
      await controller.initialize();
      await controller.seekTo(const Duration(milliseconds: 600));

      final words = [
        SubtitleWord(text: 'Hello', start: 0.4, end: 0.8),
        SubtitleWord(text: 'there', start: 0.85, end: 1.2),
      ];
      String? editedText;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 240,
              child: InteractiveSubtitleOverlay(
                words: words,
                player: controller,
                fontSize: 24,
                showBackground: true,
                onWordEdited: (w, next) {
                  w.text = next;
                  editedText = next;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Hello'), findsWidgets);
      expect(find.text('there'), findsWidgets);

      await tester.tap(find.text('Hello').last);
      await tester.pumpAndSettle();
      expect(find.text('Edit word'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Hi');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(editedText, 'Hi');
      expect(find.text('Hi'), findsWidgets);

      await tester.pumpWidget(const SizedBox());
      unawaited(controller.dispose());
    });

    testWidgets(
        'exactTimelineOnly hides text outside timeline window, supports fontStyle, and moves cleanly',
        (tester) async {
      final controller = VideoPlayerController.file(
        File('${tempDir.path}/dummy.mp4'),
      );
      await controller.initialize();
      await controller.seekTo(const Duration(milliseconds: 600));

      final words = [
        SubtitleWord(text: 'Now', start: 0.4, end: 0.8),
        SubtitleWord(text: 'Later', start: 1.5, end: 2.0),
      ];
      Offset? movedTo;
      var beforeEditCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 240,
              child: InteractiveSubtitleOverlay(
                words: words,
                player: controller,
                fontSize: 30,
                fontStyle: SubtitleFontStyle.serif,
                exactTimelineOnly: true,
                onBeforeEdit: () => beforeEditCalled = true,
                onPositionChanged: (offset) => movedTo = offset,
                onWordEdited: (w, next) => w.text = next,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // At 0.6s, only 'Now' is within its [0.4, 0.8] timeline window.
      expect(find.text('Now'), findsWidgets);
      expect(find.text('Later'), findsNothing);

      // Drag subtitle upwards -> movable position updates.
      await tester.drag(find.text('Now').last, const Offset(0, -80));
      await tester.pumpAndSettle();
      expect(movedTo, isNotNull);
      expect(movedTo!.dy, lessThan(0.65));

      // Tap to edit pauses via onBeforeEdit and updates word text.
      await tester.tap(find.text('Now').last);
      await tester.pumpAndSettle();
      expect(beforeEditCalled, isTrue);
      await tester.enterText(find.byType(TextField), 'Updated');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Updated'), findsWidgets);

      // Seek to gap (1.1s): nothing appears on screen.
      await controller.seekTo(const Duration(milliseconds: 1100));
      await tester.pump();
      expect(find.text('Updated'), findsNothing);
      expect(find.text('Later'), findsNothing);

      // Seek into second word's window (1.7s): only 'Later' appears.
      await controller.seekTo(const Duration(milliseconds: 1700));
      await tester.pumpAndSettle();
      expect(find.text('Updated'), findsNothing);
      expect(find.text('Later'), findsWidgets);

      await tester.pumpWidget(const SizedBox());
      unawaited(controller.dispose());
    });
  });

  group('SubtitleTimelineEditor', () {
    testWidgets('renders word chips, seeks on tap, drags preserving duration, and adds words',
        (tester) async {
      final controller = VideoPlayerController.file(
        File('${tempDir.path}/dummy.mp4'),
      );
      await controller.initialize();
      await controller.seekTo(const Duration(seconds: 2));

      final words = [
        SubtitleWord(text: 'First', start: 1.0, end: 1.6),
      ];
      double? soughtTo;
      SubtitleWord? movedWord;
      SubtitleWord? addedWord;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubtitleTimelineEditor(
              words: words,
              player: controller,
              totalDurationSeconds: 12.0,
              onWordMoved: (w) => movedWord = w,
              onWordEdited: (w, t) => w.text = t,
              onWordDeleted: words.remove,
              onWordAdded: (w) {
                addedWord = w;
                words.add(w);
              },
              onSeek: (s) => soughtTo = s,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap chip -> seeks to word.start (1.0) and shows Edit header button
      await tester.tap(find.text('First'));
      await tester.pumpAndSettle();
      expect(soughtTo, 1.0);
      expect(find.text('Edit'), findsOneWidget);

      // Edit via header Edit button
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'EditedFirst');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(words.first.text, 'EditedFirst');

      // Drag chip right by 70px (20px touch slop + 50px delta = +0.5s at 100 px/s)
      await tester.drag(find.text('EditedFirst'), const Offset(70, 0));
      await tester.pumpAndSettle();
      expect(movedWord, isNotNull);
      expect(words.first.start, closeTo(1.5, 0.05));
      expect(words.first.end - words.first.start, closeTo(0.6, 0.01));

      // Add word via Add Word button
      await tester.tap(find.text('Add Word'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Inserted');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(addedWord?.text, 'Inserted');
      expect(addedWord?.start, closeTo(2.0, 0.01));

      await tester.pumpWidget(const SizedBox());
      unawaited(controller.dispose());
    });
  });

  group('SubtitleStudioScreen', () {
    testWidgets('picks gallery video, generates subtitles via Gemini, and displays CapCut timeline + bouncy overlay',
        (tester) async {
      final videoFile = File('${tempDir.path}/clip.mp4')
        ..writeAsBytesSync([1, 2, 3]);
      await ApiKeyStore.save('AQ.test-key');

      final mockClient = MockClient((request) async {
        if (request.method == 'POST' &&
            request.url.queryParameters['upload_id'] == 'xyz') {
          return http.Response(
            jsonEncode({
              'file': {
                'name': 'files/clip1',
                'uri': 'https://generativelanguage.googleapis.com/v1beta/files/clip1',
              },
            }),
            200,
          );
        }
        if (request.method == 'POST' &&
            request.url.path == '/upload/v1beta/files') {
          return http.Response(
            '',
            200,
            headers: {
              'x-goog-upload-url':
                  'https://generativelanguage.googleapis.com/upload/v1beta/files?upload_id=xyz',
            },
          );
        }
        if (request.method == 'GET' &&
            request.url.path == '/v1beta/files/clip1') {
          return http.Response(jsonEncode({'state': 'ACTIVE'}), 200);
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith(':generateContent')) {
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {
                        'text': jsonEncode([
                          {'word': 'Welcome', 'start_ms': 0, 'end_ms': 500},
                          {'word': 'everyone', 'start_ms': 550, 'end_ms': 1100},
                        ]),
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      });

      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleStudioScreen(
            videoPicker: () async => XFile(videoFile.path),
            subtitleServiceBuilder: () =>
                GeminiSubtitleService(client: mockClient),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Select Video from Gallery'), findsOneWidget);
      await tester.tap(find.text('Select Video from Gallery'));
      await tester.pumpAndSettle();

      // CapCut layout: Video preview + timeline + Generate Subtitles button
      expect(find.byType(SubtitleTimelineEditor), findsOneWidget);
      expect(find.text('Generate Subtitles'), findsOneWidget);

      await tester.tap(find.text('Generate Subtitles'));
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        if (find.byType(InteractiveSubtitleOverlay).evaluate().isNotEmpty) {
          break;
        }
        final snackBars = find.byType(SnackBar).evaluate();
        if (snackBars.isNotEmpty) {
          final snackBar = snackBars.first.widget as SnackBar;
          if (snackBar.content is Text) {
            fail('Unexpected SnackBar: ${(snackBar.content as Text).data}');
          }
          fail('Unexpected SnackBar shown during subtitle generation');
        }
      }
      await tester.pump(const Duration(milliseconds: 300));

      // Both the bouncy overlay and timeline chips match exact timeline position at t=0.
      expect(find.byType(InteractiveSubtitleOverlay), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(InteractiveSubtitleOverlay),
          matching: find.text('Welcome'),
        ),
        findsWidgets,
      );
      expect(
        find.descendant(
          of: find.byType(InteractiveSubtitleOverlay),
          matching: find.text('everyone'),
        ),
        findsNothing,
      );
      expect(find.text('everyone'), findsWidgets);
      expect(find.text('Exact Sync'), findsOneWidget);
      expect(find.text('Serif'), findsOneWidget);
      expect(find.text('Export Video with Subtitles'), findsOneWidget);
      expect(find.text('TIMELINE (2 words)'), findsOneWidget);

      // Switch font style and move overlay vertically to reveal Reset Pos.
      await tester.ensureVisible(find.text('Serif'));
      await tester.pump();
      await tester.tap(find.text('Serif'));
      await tester.pump();
      final styledOverlay = tester.widget<InteractiveSubtitleOverlay>(
        find.byType(InteractiveSubtitleOverlay),
      );
      expect(styledOverlay.fontStyle, SubtitleFontStyle.serif);
      await tester.drag(
        find.descendant(
          of: find.byType(InteractiveSubtitleOverlay),
          matching: find.text('Welcome'),
        ).last,
        const Offset(0, -60),
      );
      await tester.pump();
      expect(find.text('Reset Pos'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('shows determinate progress bar while generating subtitles',
        (tester) async {
      final videoFile = File('${tempDir.path}/loading.mp4')
        ..writeAsBytesSync([1, 2, 3, 4]);
      await ApiKeyStore.save('AQ.test-key');

      final gate = Completer<void>();
      final mockClient = MockClient((request) async {
        if (request.method == 'POST' &&
            request.url.path == '/upload/v1beta/files') {
          await gate.future;
          return http.Response('{"error":{"message":"stop"}}', 500);
        }
        return http.Response('{}', 200);
      });

      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleStudioScreen(
            videoPicker: () async => XFile(videoFile.path),
            subtitleServiceBuilder: () =>
                GeminiSubtitleService(client: mockClient),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Select Video from Gallery'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Generate Subtitles'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));

      final indicator = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(indicator.value, isNotNull);
      expect(find.textContaining('%'), findsWidgets);

      final genButtonFinder = find.ancestor(
        of: find.textContaining('Generating ('),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      );
      final genButton = tester.widget<ButtonStyleButton>(genButtonFinder);
      expect(
        genButton.style?.foregroundColor?.resolve({WidgetState.disabled}),
        const Color(0xffffe500),
      );
      expect(
        genButton.style?.backgroundColor?.resolve({WidgetState.disabled}),
        const Color(0xff2c2c32),
      );
      final spinner = tester.widget<CircularProgressIndicator>(
        find.descendant(
          of: genButtonFinder,
          matching: find.byType(CircularProgressIndicator),
        ),
      );
      expect(spinner.color, const Color(0xffffe500));
      expect(find.text('Cancel'), findsOneWidget);

      await tester.ensureVisible(find.text('Cancel'));
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('Generate Subtitles'), findsOneWidget);

      gate.complete();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(find.textContaining('Subtitle generation failed'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets(
        'never shows API key dialog when pressing Generate Subtitles or in app bar',
        (tester) async {
      final videoFile = File('${tempDir.path}/nokey.mp4')
        ..writeAsBytesSync([1, 2, 3, 4]);

      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleStudioScreen(
            videoPicker: () async => XFile(videoFile.path),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.key), findsNothing);
      await tester.tap(find.text('Select Video from Gallery'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Generate Subtitles'));
      await tester.pump();
      await tester.tap(find.text('Generate Subtitles'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        if (find.byType(SnackBar).evaluate().isNotEmpty) {
          break;
        }
      }
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Gemini API Key'), findsNothing);
      expect(
        find.text('Auto-subtitles are unavailable in this build. Please contact support.'),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}
