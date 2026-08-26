import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// macOS speech input for Studio's AI prompt.
///
/// Kept behind a tiny wrapper so other backends can be swapped in later.
class MacVoiceInput extends ChangeNotifier {
  final SpeechToText _speech = SpeechToText();

  bool _initialized = false;
  bool _available = false;
  bool _listening = false;
  String transcript = '';
  String? error;

  bool get available => _available;
  bool get listening => _listening;

  Future<void> start() async {
    if (!Platform.isMacOS) return;
    error = null;
    if (!_initialized) {
      try {
        _available = await _speech.initialize(
          onStatus: _onStatus,
          onError: _onError,
        );
      } on Object catch (e) {
        error = 'voice: $e';
        _available = false;
      }
      _initialized = true;
    }
    if (!_available || _listening) {
      notifyListeners();
      return;
    }
    transcript = '';
    _listening = true;
    notifyListeners();
    await _speech.listen(
      onResult: _onResult,
      listenOptions: SpeechListenOptions(partialResults: true),
    );
  }

  Future<String> stop() async {
    if (!_listening) return transcript.trim();
    await _speech.stop();
    _listening = false;
    notifyListeners();
    return transcript.trim();
  }

  void _onResult(SpeechRecognitionResult result) {
    transcript = result.recognizedWords;
    notifyListeners();
  }

  void _onStatus(String status) {
    final nowListening = status == 'listening';
    if (_listening != nowListening && status == 'notListening') {
      _listening = false;
      notifyListeners();
    }
  }

  void _onError(SpeechRecognitionError e) {
    error = e.errorMsg;
    _listening = false;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_listening) _speech.stop();
    super.dispose();
  }
}
