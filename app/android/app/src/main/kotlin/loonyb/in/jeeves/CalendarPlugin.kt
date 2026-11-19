package loonyb.`in`.jeeves

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Reads the device calendar for the day timeline. Read-only, in one file.
 *
 * Channel: "jeeves/calendar"
 *   requestPermission()                  -> Boolean (asks the user once if needed)
 *   readEvents({fromMillis, toMillis})   -> List<{id, title, startMillis, endMillis, allDay}>
 *       error "permission_denied" when READ_CALENDAR is not granted,
 *       error "unavailable" when the provider fails.
 *
 * Privacy contract (a hard requirement for review): event ids, titles and times
 * are only ever copied into the result of one call. They are not cached, not
 * written anywhere, and never passed to Log, print or an exception message.
 * Only READ_CALENDAR is requested; nothing here can write to a calendar.
 */
class CalendarPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener {

    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestPermission" -> requestPermission(result)
            "readEvents" -> readEvents(call, result)
            else -> result.notImplemented()
        }
    }

    private fun hasPermission(): Boolean {
        val appContext = context ?: return false
        return ContextCompat.checkSelfPermission(
            appContext, Manifest.permission.READ_CALENDAR
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestPermission(result: MethodChannel.Result) {
        if (hasPermission()) {
            result.success(true)
            return
        }
        val host = activity
        if (host == null || pendingPermissionResult != null) {
            result.success(false)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            host, arrayOf(Manifest.permission.READ_CALENDAR), PERMISSION_REQUEST_CODE
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
        return true
    }

    private fun readEvents(call: MethodCall, result: MethodChannel.Result) {
        if (!hasPermission()) {
            result.error("permission_denied", null, null)
            return
        }
        val appContext = context
        val fromMillis = (call.argument<Number>("fromMillis"))?.toLong()
        val toMillis = (call.argument<Number>("toMillis"))?.toLong()
        if (appContext == null || fromMillis == null || toMillis == null) {
            result.error("unavailable", null, null)
            return
        }
        try {
            val uri = CalendarContract.Instances.CONTENT_URI.buildUpon()
                .also {
                    ContentUris.appendId(it, fromMillis)
                    ContentUris.appendId(it, toMillis)
                }
                .build()
            val rows = ArrayList<Map<String, Any>>()
            appContext.contentResolver.query(uri, PROJECTION, null, null, SORT_ORDER)
                ?.use { cursor ->
                    while (cursor.moveToNext()) {
                        // Hidden calendars, cancelled events and events the user
                        // declined do not block time.
                        if (cursor.getInt(COL_VISIBLE) == 0) continue
                        if (cursor.getInt(COL_STATUS) == CalendarContract.Events.STATUS_CANCELED) continue
                        if (cursor.getInt(COL_SELF_STATUS) ==
                            CalendarContract.Attendees.ATTENDEE_STATUS_DECLINED
                        ) continue
                        rows.add(
                            mapOf(
                                "id" to "${cursor.getLong(COL_EVENT_ID)}:${cursor.getLong(COL_BEGIN)}",
                                "title" to (cursor.getString(COL_TITLE) ?: ""),
                                "startMillis" to cursor.getLong(COL_BEGIN),
                                "endMillis" to cursor.getLong(COL_END),
                                "allDay" to (cursor.getInt(COL_ALL_DAY) == 1),
                            )
                        )
                    }
                } ?: run {
                result.error("unavailable", null, null)
                return
            }
            result.success(rows)
        } catch (e: SecurityException) {
            result.error("permission_denied", null, null)
        } catch (e: Exception) {
            // The message is dropped on purpose: it must never carry event fields.
            result.error("unavailable", null, null)
        }
    }

    private companion object {
        const val CHANNEL = "jeeves/calendar"
        const val PERMISSION_REQUEST_CODE = 4107
        const val SORT_ORDER = "begin ASC"

        val PROJECTION = arrayOf(
            CalendarContract.Instances.EVENT_ID,
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
            CalendarContract.Instances.ALL_DAY,
            CalendarContract.Instances.STATUS,
            CalendarContract.Instances.SELF_ATTENDEE_STATUS,
            CalendarContract.Instances.VISIBLE,
        )
        const val COL_EVENT_ID = 0
        const val COL_TITLE = 1
        const val COL_BEGIN = 2
        const val COL_END = 3
        const val COL_ALL_DAY = 4
        const val COL_STATUS = 5
        const val COL_SELF_STATUS = 6
        const val COL_VISIBLE = 7
    }
}
