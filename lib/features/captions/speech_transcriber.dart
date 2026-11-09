import 'dart:async';

import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../core/models/subtitle_word.dart';
import '../../core/models/transcript_builder.dart';

/// Listens to the microphone while a take is recorded and produces word
/// timings relative to the start of the recording.
class SpeechTranscriber {
  final SpeechToText _speech = SpeechToText();
  final TranscriptBuilder _builder = TranscriptBuilder();
  DateTime? _origin;
  bool _active = false;
  bool _restarting = false;

  double get _now =>
      DateTime.now().difference(_origin ?? DateTime.now()).inMilliseconds /
      1000;

  /// Starts listening. [origin] is the moment the video recording began.
  /// Returns false if speech recognition is unavailable or not permitted.
  Future<bool> start(DateTime origin) async {
    _origin = origin;
    try {
      final ready = await _speech.initialize(
        onStatus: _onStatus,
        onError: _onError,
      );
      if (!ready) return false;
      _active = true;
      await _listen();
      return true;
    } catch (_) {
      _active = false;
      return false;
    }
  }

  Future<void> _listen() async {
    await _speech.listen(
      onResult: _onResult,
      listenOptions: SpeechListenOptions(
        partialResults: true,
        listenMode: ListenMode.dictation,
        cancelOnError: false,
        listenFor: const Duration(minutes: 5),
        pauseFor: const Duration(seconds: 8),
      ),
    );
  }

  void _onResult(SpeechRecognitionResult result) {
    _builder.update(result.recognizedWords, _now);
    if (result.finalResult) _builder.commitSession();
  }

  void _onStatus(String status) {
    if (!_active || _restarting) return;
    if (status != 'done' && status != 'notListening') return;
    // The recognizer ends a session after silence; keep going.
    _restarting = true;
    _builder.commitSession();
    Timer(const Duration(milliseconds: 250), () async {
      try {
        if (_active) await _listen();
      } catch (_) {
        _active = false;
      } finally {
        _restarting = false;
      }
    });
  }

  void _onError(SpeechRecognitionError error) {
    if (error.permanent) _active = false;
  }

  /// Stops listening and returns every word heard, in order.
  Future<List<SubtitleWord>> stop() async {
    _active = false;
    try {
      await _speech.stop();
      // Let the recognizer deliver its final result.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _speech.cancel();
    } catch (_) {}
    _builder.commitSession();
    return _builder.words;
  }

  void cancel() {
    _active = false;
    unawaited(_speech.cancel().catchError((_) {}));
  }
}
