package loonyb.`in`.jeeves

import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(MwaPlugin())
        // FLAG_SECURE, on request from lib/services/secure_screen.dart. Needed by
        // any surface that shows a secret once: without it the system's recents
        // thumbnail is a real capture of the recovery passphrase, taken with no
        // user action and kept until the task is dismissed.
        //
        // Window-scoped, so the Dart side clears it on the way out. No permission
        // is involved, and nothing is persisted.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SECURE_SCREEN_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSecure" -> {
                        // Fail *closed*: a malformed call sets the flag rather than
                        // clearing it.
                        val secure = call.argument<Boolean>("secure") ?: true
                        runOnUiThread {
                            if (secure) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            }
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private companion object {
        const val SECURE_SCREEN_CHANNEL = "jeeves/secure_screen"
    }
}
