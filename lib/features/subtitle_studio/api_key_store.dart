import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Resolves the Gemini API key from persistent storage, compile-time
/// `--dart-define=GEMINI_API_KEY=...`, or the Android debug `.env` bridge.
class ApiKeyStore {
  static const String _prefKey = 'gemini_api_key';
  static const String _envKey = String.fromEnvironment('GEMINI_API_KEY');
  static const MethodChannel _devChannel = MethodChannel(
    'cue_mobile/dev_config',
  );

  /// Returns the saved/configured Gemini API key, or `null` if unavailable.
  static Future<String?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefKey)?.trim();
    if (stored != null && stored.isNotEmpty) {
      return stored;
    }
    final env = _envKey.trim();
    if (env.isNotEmpty) {
      return env;
    }
    if (kDebugMode) {
      try {
        final devKey =
            (await _devChannel.invokeMethod<String>('getDevGeminiApiKey'))
                ?.trim();
        if (devKey != null && devKey.isNotEmpty) {
          return devKey;
        }
      } on MissingPluginException {
        // Channel unavailable in unit tests and non-Android targets.
      } catch (_) {}
    }
    return null;
  }

  /// Saves [key] to persistent storage.
  static Future<void> save(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, key.trim());
  }

  /// Clears any saved API key from persistent storage.
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
  }
}
