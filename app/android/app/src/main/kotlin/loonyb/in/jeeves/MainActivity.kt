package loonyb.`in`.jeeves

import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(MwaPlugin())
        flutterEngine.plugins.add(CalendarPlugin())
        // The folder channel: the system folder picker and the document tree it
        // grants. One channel, one picker, no broad storage permission.
        flutterEngine.plugins.add(FolderStoragePlugin())
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

        // The name the platform gives this device, asked for by
        // lib/services/platform_device_name.dart. The OS device name is what
        // the user calls the phone ("Galaxy S23", or whatever they renamed it
        // to); Build.MODEL is the fallback for the devices where that setting
        // is blank or unreadable.
        //
        // A default and nothing more: the user can change it, and it is the
        // user's own preferences Workspace that carries it, never this channel.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_NAME_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDeviceName" -> result.success(deviceName())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * The OS device name, or the model when that setting is blank or cannot
     * be read.
     *
     * The settings read is wrapped because the setting is not guaranteed to
     * be there on every device or every Android version, and a device that
     * cannot answer is still a device — it just answers with its model.
     */
    private fun deviceName(): String {
        val fromSettings: String? = try {
            Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
        } catch (error: Exception) {
            null
        }
        return fromSettings?.takeIf { it.isNotBlank() } ?: Build.MODEL
    }

    private companion object {
        const val SECURE_SCREEN_CHANNEL = "jeeves/secure_screen"
        const val DEVICE_NAME_CHANNEL = "jeeves/device_name"
    }
}
