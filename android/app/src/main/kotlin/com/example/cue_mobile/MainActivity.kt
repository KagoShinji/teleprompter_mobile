package com.example.cue_mobile

import android.content.pm.ApplicationInfo
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "cue_mobile/dev_config"
        ).setMethodCallHandler { call, result ->
            if (call.method == "getDevGeminiApiKey") {
                val isDebug = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
                if (!isDebug) {
                    result.success(null)
                    return@setMethodCallHandler
                }
                val b64 = getString(R.string.dev_gemini_api_key_b64).trim()
                if (b64.isEmpty()) {
                    result.success(null)
                } else {
                    val decoded = String(Base64.decode(b64, Base64.DEFAULT), Charsets.UTF_8).trim()
                    result.success(decoded.ifEmpty { null })
                }
            } else {
                result.notImplemented()
            }
        }
    }
}
