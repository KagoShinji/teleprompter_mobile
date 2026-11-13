import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/return_code.dart';
import 'package:http/http.dart' as http;

import '../../core/models/subtitle_word.dart';
import 'audio_speech_aligner.dart';

/// Uploads video/audio to the Gemini Files API using the resumable upload
/// protocol, waits for it to become ACTIVE, then calls generateContent to
/// extract word-level speech-to-text timestamps.
class GeminiSubtitleService {
  GeminiSubtitleService({
    http.Client? client,
    this.audioExtractor,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final Future<File?> Function(String videoPath)? audioExtractor;
  bool _cancelled = false;

  /// Cancels any in-flight transcription and aborts an owned HTTP client.
  void cancel() {
    _cancelled = true;
    if (_ownsClient) {
      try {
        _client.close();
      } catch (_) {}
    }
  }

  static const String _baseUrl =
      'https://generativelanguage.googleapis.com';

  // Prioritize low-latency models with accurate MM:SS.mmm timestamp tracking.
  static const List<String> _candidateModels = [
    'gemini-3.1-flash-lite',
    'gemini-3.5-flash-lite',
    'gemini-3.6-flash',
    'gemini-3.5-flash',
  ];

  /// Transcribes [videoPath] using Gemini Flash multimodal STT.
  ///
  /// [onStatus] is called with human-readable progress messages, and
  /// [onProgress] emits a monotonic 0.0–1.0 completion fraction across audio
  /// prep, upload, processing, transcription, and timeline sync.
  /// Throws a descriptive [Exception] on any failure.
  Future<List<SubtitleWord>> transcribe(
    String videoPath,
    String apiKey, {
    void Function(String status)? onStatus,
    void Function(double progress)? onProgress,
    Duration pollInterval = const Duration(seconds: 2),
    Duration requestTimeout = const Duration(seconds: 45),
  }) async {
    final trimmedKey = apiKey.trim();
    if (trimmedKey.isEmpty) {
      throw Exception('Please enter a valid Gemini API key.');
    }

    final file = File(videoPath);
    if (!file.existsSync()) {
      throw Exception('Video file not found: $videoPath');
    }

    var highestProgress = -1.0;
    void emitProgress(double p) {
      if (_cancelled) return;
      final clamped = p.clamp(0.0, 1.0);
      if (clamped > highestProgress) {
        highestProgress = clamped;
        onProgress?.call(clamped);
      }
    }

    File? extractedAudio;
    List<SpeechSegment> speechSegments = const [];
    String? uploadedFileName;
    try {
      // ── 0. Extract PTS-locked audio & acoustic speech segments locally ─────
      emitProgress(0.02);
      onStatus?.call('Preparing audio for fast transcription…');
      final prepared = await _prepareAudioAndSegments(videoPath);
      extractedAudio = prepared.audioFile;
      speechSegments = prepared.segments;
      if (_cancelled) throw StateError('Cancelled');
      final mediaFile = extractedAudio ?? file;

      // ── 1. Resumable upload to Gemini Files API ──────────────────────────
      emitProgress(0.04);
      onStatus?.call(
        extractedAudio != null
            ? 'Uploading audio to Gemini…'
            : 'Uploading video to Gemini…',
      );
      final uploadResult = await _uploadResumable(
        mediaFile,
        trimmedKey,
        onStatus: onStatus,
        onProgress: emitProgress,
      );
      if (_cancelled) throw StateError('Cancelled');
      uploadedFileName = uploadResult.name;
      final fileUri = uploadResult.uri;
      final mimeType = uploadResult.mimeType;

      // ── 2. Poll until ACTIVE ─────────────────────────────────────────────
      emitProgress(0.50);
      onStatus?.call('Processing video audio…');
      await _waitUntilActive(
        uploadedFileName,
        trimmedKey,
        onStatus,
        onProgress: emitProgress,
        pollInterval: pollInterval,
      );
      if (_cancelled) throw StateError('Cancelled');

      // ── 3. Request word-level timestamps ─────────────────────────────────
      emitProgress(0.70);
      onStatus?.call('Generating speech-to-text subtitles…');
      const prompt = '''
Transcribe every spoken word in this audio with exact timestamps.
Format "start" and "end" strictly as MM:SS.mmm from audio start (for example "00:01.600" and "00:02.350").
Return ONLY a JSON array where each element has:
- "word": string (the single spoken word)
- "start": string ("MM:SS.mmm")
- "end": string ("MM:SS.mmm")

Ensure start < end for each word and keep silent pauses completely empty without stretching word durations.
If there is no speech, return [].''';

      final rawText = await _generateWithFallback(
        apiKey: trimmedKey,
        mimeType: mimeType,
        fileUri: fileUri,
        prompt: prompt,
        onStatus: onStatus,
        onProgress: emitProgress,
        requestTimeout: requestTimeout,
      );

      // ── 4. Parse JSON & align against acoustic speech segments ───────────
      emitProgress(0.95);
      onStatus?.call('Syncing subtitles to timeline…');
      final parsed = _parseWords(rawText);
      final aligned = speechSegments.isNotEmpty
          ? AudioSpeechAligner.alignWordsToSegments(parsed, speechSegments)
          : parsed;
      emitProgress(1.0);
      return aligned;
    } finally {
      if (extractedAudio != null && extractedAudio.existsSync()) {
        try {
          extractedAudio.deleteSync();
        } catch (_) {}
      }
      if (uploadedFileName != null) {
        unawaited(_deleteRemoteFile(uploadedFileName, trimmedKey));
      }
      if (_ownsClient) {
        _client.close();
      }
    }
  }

  Future<({File? audioFile, List<SpeechSegment> segments})>
      _prepareAudioAndSegments(String videoPath) async {
    final customExtractor = audioExtractor;
    if (customExtractor != null) {
      try {
        return (audioFile: await customExtractor(videoPath), segments: const <SpeechSegment>[]);
      } catch (_) {
        return (audioFile: null, segments: const <SpeechSegment>[]);
      }
    }

    final stamp = DateTime.now().millisecondsSinceEpoch;
    final tmpDir = Directory.systemTemp.path;
    final m4aPath = '$tmpDir${Platform.pathSeparator}cue_stt_$stamp.m4a';
    final wavPath = '$tmpDir${Platform.pathSeparator}cue_vad_$stamp.wav';
    final escapedInput = videoPath.replaceAll('"', r'\"');
    final escapedM4a = m4aPath.replaceAll('"', r'\"');
    final escapedWav = wavPath.replaceAll('"', r'\"');

    // Pad container audio offsets to t=0.000s (first_pts=0) so audio stays
    // locked to VideoPlayer's video timeline, and decode 8kHz PCM for VAD sync.
    final dualCommand =
        '-y -i "$escapedInput" -vn -af aresample=async=1:first_pts=0 -ac 1 -ar 16000 -c:a aac -b:a 48k "$escapedM4a" '
        '-vn -af aresample=async=1:first_pts=0 -ac 1 -ar 8000 -c:a pcm_s16le "$escapedWav"';

    var ok = await _runFfmpegCommand(dualCommand);
    final m4aFile = File(m4aPath);
    final wavFile = File(wavPath);

    if (!ok || !m4aFile.existsSync() || m4aFile.lengthSync() <= 256) {
      _safeDelete(m4aFile);
      _safeDelete(wavFile);
      final fallbackCmd =
          '-y -i "$escapedInput" -vn -ac 1 -ar 16000 -c:a aac -b:a 48k "$escapedM4a"';
      ok = await _runFfmpegCommand(fallbackCmd);
      if (!ok || !m4aFile.existsSync() || m4aFile.lengthSync() <= 256) {
        _safeDelete(m4aFile);
        return (audioFile: null, segments: const <SpeechSegment>[]);
      }
      return (audioFile: m4aFile, segments: const <SpeechSegment>[]);
    }

    List<SpeechSegment> segments = const [];
    try {
      if (wavFile.existsSync()) {
        segments = AudioSpeechAligner.detectSpeechSegmentsFromWav(wavFile);
      }
    } catch (_) {
      segments = const [];
    } finally {
      _safeDelete(wavFile);
    }

    return (audioFile: m4aFile, segments: segments);
  }

  Future<bool> _runFfmpegCommand(String command) async {
    final completer = Completer<bool>();
    try {
      await FFmpegKit.executeAsync(command, (session) async {
        final rc = await session.getReturnCode();
        if (!completer.isCompleted) {
          completer.complete(ReturnCode.isSuccess(rc));
        }
      });
      return await completer.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => false,
      );
    } catch (_) {
      return false;
    }
  }

  void _safeDelete(File file) {
    if (file.existsSync()) {
      try {
        file.deleteSync();
      } catch (_) {}
    }
  }

  Future<({String name, String uri, String mimeType})> _uploadResumable(
    File file,
    String apiKey, {
    void Function(String)? onStatus,
    void Function(double)? onProgress,
  }) async {
    final byteLength = await file.length();
    final mimeType = _mimeType(file.path);
    final displayName = file.uri.pathSegments.isNotEmpty
        ? file.uri.pathSegments.last
        : 'video.mp4';

    final startUri = Uri.parse('$_baseUrl/upload/v1beta/files');
    final startResponse = await _client
        .post(
          startUri,
          headers: {
            'x-goog-api-key': apiKey,
            'X-Goog-Upload-Protocol': 'resumable',
            'X-Goog-Upload-Command': 'start',
            'X-Goog-Upload-Header-Content-Length': '$byteLength',
            'X-Goog-Upload-Header-Content-Type': mimeType,
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'file': {'display_name': displayName},
          }),
        )
        .timeout(const Duration(seconds: 20));

    if (startResponse.statusCode != 200) {
      throw Exception(
        _formatApiError(
          'Could not start Gemini upload',
          startResponse.statusCode,
          startResponse.body,
        ),
      );
    }

    String? uploadUrl;
    for (final entry in startResponse.headers.entries) {
      if (entry.key.toLowerCase() == 'x-goog-upload-url') {
        uploadUrl = entry.value;
        break;
      }
    }
    if (uploadUrl == null || uploadUrl.isEmpty) {
      throw Exception('Gemini upload did not return an upload URL.');
    }

    final uploadRequest = http.StreamedRequest('POST', Uri.parse(uploadUrl))
      ..contentLength = byteLength
      ..headers['Content-Length'] = '$byteLength'
      ..headers['X-Goog-Upload-Offset'] = '0'
      ..headers['X-Goog-Upload-Command'] = 'upload, finalize';

    final isAudioOnly = mimeType.startsWith('audio/');
    final uploadLabel = isAudioOnly ? 'Uploading audio' : 'Uploading video';
    var sentBytes = 0;
    var lastPercent = -1;
    final trackedStream = file.openRead().map((chunk) {
      sentBytes += chunk.length;
      if (byteLength > 0) {
        final fraction = (sentBytes / byteLength).clamp(0.0, 1.0);
        final pct = (fraction * 100).round();
        if (pct != lastPercent) {
          lastPercent = pct;
          onProgress?.call(0.05 + fraction * 0.40);
          onStatus?.call('$uploadLabel to Gemini… $pct%');
        }
      }
      return chunk;
    });

    final addStreamFuture = uploadRequest.sink
        .addStream(trackedStream)
        .then((_) => uploadRequest.sink.close());

    final streamedResponse = await _client
        .send(uploadRequest)
        .timeout(const Duration(seconds: 120));
    await addStreamFuture;

    final uploadBody = await streamedResponse.stream
        .bytesToString()
        .timeout(const Duration(seconds: 30));
    if (streamedResponse.statusCode != 200) {
      throw Exception(
        _formatApiError(
          'Video upload failed',
          streamedResponse.statusCode,
          uploadBody,
        ),
      );
    }

    final uploadJson = jsonDecode(uploadBody) as Map<String, dynamic>;
    final fileInfo =
        (uploadJson['file'] as Map<String, dynamic>?) ?? uploadJson;
    final fileName = fileInfo['name'] as String? ?? '';
    final fileUri = fileInfo['uri'] as String? ?? '';
    if (fileName.isEmpty || fileUri.isEmpty) {
      throw Exception('Unexpected upload response from Gemini: $uploadBody');
    }

    return (name: fileName, uri: fileUri, mimeType: mimeType);
  }

  Future<void> _waitUntilActive(
    String fileName,
    String apiKey,
    void Function(String)? onStatus, {
    void Function(double)? onProgress,
    required Duration pollInterval,
  }) async {
    const maxAttempts = 90;
    for (int i = 0; i < maxAttempts; i++) {
      if (_cancelled) throw StateError('Cancelled');
      final checkUri = Uri.parse('$_baseUrl/v1beta/$fileName');
      final res = await _client
          .get(
            checkUri,
            headers: {'x-goog-api-key': apiKey},
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        throw Exception(
          _formatApiError(
            'File status check failed',
            res.statusCode,
            res.body,
          ),
        );
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final state = data['state'] as String? ?? '';
      if (state == 'ACTIVE') {
        onProgress?.call(0.65);
        return;
      }
      if (state == 'FAILED') {
        throw Exception('Gemini file processing failed: ${data['error']}');
      }
      onProgress?.call((0.50 + math.min(i + 1, 14) * 0.01).clamp(0.50, 0.64));
      onStatus?.call('Processing audio… (${i + 1})');
      await Future<void>.delayed(pollInterval);
    }
    throw Exception('Timed out waiting for Gemini to process the media.');
  }

  static String _thinkingLevelFor(String model) {
    switch (model) {
      case 'gemini-3.1-flash-lite':
      case 'gemini-3.6-flash':
        return 'low';
      default:
        return 'minimal';
    }
  }

  Future<String> _generateWithFallback({
    required String apiKey,
    required String mimeType,
    required String fileUri,
    required String prompt,
    required Duration requestTimeout,
    void Function(String)? onStatus,
    void Function(double)? onProgress,
  }) async {
    String buildBodyFor(String model) {
      return jsonEncode({
        'contents': [
          {
            'parts': [
              {
                'file_data': {
                  'mime_type': mimeType,
                  'file_uri': fileUri,
                },
              },
              {'text': prompt},
            ],
          }
        ],
        'generationConfig': {
          'temperature': 0,
          'thinkingConfig': {
            'thinkingLevel': _thinkingLevelFor(model),
          },
          'responseMimeType': 'application/json',
          'responseSchema': {
            'type': 'ARRAY',
            'items': {
              'type': 'OBJECT',
              'properties': {
                'word': {'type': 'STRING'},
                'start': {'type': 'STRING'},
                'end': {'type': 'STRING'},
              },
              'required': ['word', 'start', 'end'],
            },
          },
        },
      });
    }

    Exception? lastModelError;
    for (int i = 0; i < _candidateModels.length; i++) {
      if (_cancelled) throw StateError('Cancelled');
      final model = _candidateModels[i];
      final baseProgress = (0.72 + i * 0.05).clamp(0.72, 0.87);
      onProgress?.call(baseProgress);
      onStatus?.call('Transcribing speech with $model…');

      final generateUri = Uri.parse(
        '$_baseUrl/v1beta/models/$model:generateContent',
      );
      final requestBody = buildBodyFor(model);

      Timer? ticker;
      try {
        ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (_cancelled) {
            timer.cancel();
            return;
          }
          final elapsedSec = timer.tick;
          final smooth = baseProgress +
              (0.90 - baseProgress) * (1 - math.exp(-elapsedSec / 12.0));
          onProgress?.call(smooth);
          onStatus?.call('Transcribing speech ($model, ${elapsedSec}s)…');
        });

        final response = await _client
            .post(
              generateUri,
              headers: {
                'Content-Type': 'application/json',
                'x-goog-api-key': apiKey,
              },
              body: requestBody,
            )
            .timeout(requestTimeout);

        if (response.statusCode == 200) {
          onProgress?.call(0.92);
          final generateJson =
              jsonDecode(response.body) as Map<String, dynamic>;
          final candidates =
              generateJson['candidates'] as List<dynamic>? ?? [];
          if (candidates.isEmpty) {
            throw Exception(
              'Gemini returned no transcript candidates. Ensure the video has audible speech.',
            );
          }
          final content =
              candidates[0]['content'] as Map<String, dynamic>? ?? {};
          final parts = content['parts'] as List<dynamic>? ?? [];
          if (parts.isEmpty) {
            throw Exception('Gemini returned an empty transcript response.');
          }
          return ((parts[0] as Map<String, dynamic>)['text'] as String? ?? '')
              .trim();
        }

        final error = Exception(
          _formatApiError(
            'Gemini transcription failed ($model)',
            response.statusCode,
            response.body,
          ),
        );

        // Retry next model if unavailable, throttled, or transiently failing.
        if (const {404, 429, 500, 503}.contains(response.statusCode)) {
          lastModelError = error;
          if (i + 1 < _candidateModels.length) {
            onStatus?.call(
              'Switching to backup model (${_candidateModels[i + 1]})…',
            );
          }
          continue;
        }
        throw error;
      } on TimeoutException catch (_) {
        lastModelError = Exception(
          'Gemini transcription timed out after ${requestTimeout.inSeconds}s ($model).',
        );
        if (i + 1 < _candidateModels.length) {
          onStatus?.call(
            '$model timed out, switching to ${_candidateModels[i + 1]}…',
          );
          continue;
        }
      } on SocketException catch (e) {
        lastModelError = Exception(
          'Network connection error during transcription ($model): $e',
        );
        if (i + 1 < _candidateModels.length) {
          onStatus?.call(
            'Connection interrupted, switching to ${_candidateModels[i + 1]}…',
          );
          continue;
        }
      } finally {
        ticker?.cancel();
      }
    }

    throw lastModelError ??
        Exception('No compatible Gemini Flash model was available.');
  }

  Future<void> _deleteRemoteFile(String fileName, String apiKey) async {
    try {
      final uri = Uri.parse('$_baseUrl/v1beta/$fileName');
      await _client
          .delete(uri, headers: {'x-goog-api-key': apiKey})
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Best-effort cleanup only.
    }
  }

  List<SubtitleWord> _parseWords(String rawText) {
    var text = rawText.trim();
    if (text.isEmpty) return [];

    if (text.startsWith('```')) {
      text = text
          .replaceAll(RegExp(r'^```[a-zA-Z]*\n?'), '')
          .replaceAll(RegExp(r'\n?```$'), '')
          .trim();
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (e) {
      throw Exception('Failed to parse Gemini JSON response: $e\nRaw: $text');
    }

    final List<dynamic> jsonList;
    if (decoded is List<dynamic>) {
      jsonList = decoded;
    } else if (decoded is Map<String, dynamic> &&
        decoded['words'] is List<dynamic>) {
      jsonList = decoded['words'] as List<dynamic>;
    } else {
      throw Exception('Unexpected JSON format from Gemini: $text');
    }

    final words = <SubtitleWord>[];
    for (final item in jsonList) {
      if (item is! Map<String, dynamic>) continue;
      final wordText = (item['word'] as String? ?? '').trim();
      if (wordText.isEmpty) continue;

      final rawStart = _extractTimeMs(item['start'], item['start_ms']) ?? 0;
      final rawEnd =
          _extractTimeMs(item['end'], item['end_ms']) ?? (rawStart + 250);
      final startMs = math.max(0, rawStart);
      final endMs = math.max(startMs + 50, rawEnd);

      words.add(
        SubtitleWord(
          text: wordText,
          start: startMs / 1000.0,
          end: endMs / 1000.0,
        ),
      );
    }

    words.sort((a, b) => a.start.compareTo(b.start));
    return words;
  }

  static int? _extractTimeMs(dynamic timeValue, dynamic msValue) {
    if (timeValue != null) {
      if (timeValue is num) {
        return (timeValue * 1000).round();
      }
      if (timeValue is String) {
        final parsed = _parseTimestampStringMs(timeValue.trim());
        if (parsed != null) return parsed;
      }
    }
    if (msValue is num) {
      return msValue.round();
    }
    if (msValue is String) {
      return int.tryParse(msValue.trim());
    }
    return null;
  }

  static int? _parseTimestampStringMs(String raw) {
    if (raw.isEmpty) return null;
    if (!raw.contains(':')) {
      final sec = double.tryParse(raw.replaceAll(',', '.'));
      return sec == null ? null : (sec * 1000).round();
    }
    final parts = raw.replaceAll(',', '.').split(':');
    if (parts.length == 2) {
      final mins = int.tryParse(parts[0]);
      final secs = double.tryParse(parts[1]);
      if (mins == null || secs == null) return null;
      return ((mins * 60 + secs) * 1000).round();
    }
    if (parts.length == 3) {
      final hrs = int.tryParse(parts[0]);
      final mins = int.tryParse(parts[1]);
      final secs = double.tryParse(parts[2]);
      if (hrs == null || mins == null || secs == null) return null;
      return ((hrs * 3600 + mins * 60 + secs) * 1000).round();
    }
    return null;
  }

  String _formatApiError(String prefix, int statusCode, String body) {
    try {
      final parsed = jsonDecode(body);
      if (parsed is Map<String, dynamic> &&
          parsed['error'] is Map<String, dynamic>) {
        final msg =
            (parsed['error'] as Map<String, dynamic>)['message'] as String?;
        if (msg != null && msg.isNotEmpty) {
          return '$prefix ($statusCode): $msg';
        }
      }
    } catch (_) {}
    return '$prefix ($statusCode): $body';
  }

  String _mimeType(String path) {
    final ext = path.split('.').last.toLowerCase();
    switch (ext) {
      case 'm4a':
        return 'audio/mp4';
      case 'aac':
        return 'audio/aac';
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'avi':
        return 'video/x-msvideo';
      case 'mkv':
        return 'video/x-matroska';
      case 'webm':
        return 'video/webm';
      case '3gp':
        return 'video/3gpp';
      case 'm4v':
        return 'video/x-m4v';
      default:
        return 'video/mp4';
    }
  }
}
