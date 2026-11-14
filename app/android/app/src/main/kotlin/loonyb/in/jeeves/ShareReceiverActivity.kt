package loonyb.`in`.jeeves

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.webkit.MimeTypeMap
import android.widget.Toast
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.time.Instant
import java.util.UUID

/**
 * Receives `ACTION_SEND` text, URLs and images from the Android share sheet and
 * queues them for the Dart side to turn into Inbox Captures.
 *
 * Runs no Flutter engine and shows no UI: it copies any image into app-private
 * storage, writes a pending-share JSON file, toasts, and finishes, so the user
 * stays in the app they shared from. Dart drains the queue (`lib/capture/
 * share_inbox.dart`) when Jeeves next starts or resumes, which keeps a single
 * process writing the database and op log.
 *
 * Contract — `filesDir/share_inbox/<shareId>.json`, version 1; the pinned
 * fixtures in `app/test/fixtures/share_inbox/` document the format. The file is
 * written to `.tmp`, fsynced, then renamed, so the toast only appears once the
 * share is durable. Images go straight to `filesDir/capture_attachments/`.
 *
 * Dart finds these files through `getApplicationSupportDirectory()`, so the
 * contract depends on `path_provider_android` implementing that call as
 * `Context.filesDir` (true in 2.3.1). No automated test covers the mapping: the
 * Dart journey test (`share_sheet_capture_journey_test.dart`) reads the
 * fixtures from a temporary directory it injects instead. If the mapping
 * changed, a share would still toast "Added to Inbox" and never reach the
 * Inbox. So after a `path_provider_android` upgrade, check by hand: share to
 * Jeeves on a device or emulator, open Jeeves, and confirm the Capture is in
 * the Inbox (`docs/TESTING.md`, share-sheet capture).
 */
class ShareReceiverActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A non-null saved state means the system restored this Activity (for
        // example after process death). The original share was already handled
        // or lost; queueing the replayed intent again would mint a second
        // shareId and so a duplicate Capture. Config changes never recreate it
        // (see `android:configChanges` in the manifest), so a worker is never
        // orphaned mid-copy by a recreation.
        if (savedInstanceState != null) {
            finish()
            return
        }
        val sharedIntent = intent
        Thread {
            val succeeded = try {
                queueShare(sharedIntent)
                true
            } catch (error: Exception) {
                false
            }
            runOnUiThread {
                Toast.makeText(
                    applicationContext,
                    if (succeeded) R.string.share_added_to_inbox else R.string.share_failed,
                    Toast.LENGTH_SHORT,
                ).show()
                finish()
            }
        }.start()
    }

    private fun queueShare(sharedIntent: Intent?) {
        if (sharedIntent?.action != Intent.ACTION_SEND) throw IllegalArgumentException("not a SEND intent")
        // EXTRA_TEXT and EXTRA_SUBJECT are CharSequence; styled text is not a String.
        val text = sharedIntent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        val subject = sharedIntent.getCharSequenceExtra(Intent.EXTRA_SUBJECT)?.toString()
        val stream = streamUri(sharedIntent)
        if (stream != null) requireForeignContentUri(stream)
        if (text.isNullOrBlank() && subject.isNullOrBlank() && stream == null) {
            throw IllegalArgumentException("nothing to capture")
        }

        val shareId = UUID.randomUUID().toString()
        var storedImage: File? = null
        try {
            val json = JSONObject()
                .put("version", 1)
                .put("shareId", shareId)
                .put("receivedAt", Instant.now().toString())
                .put("text", text ?: JSONObject.NULL)
                .put("subject", subject ?: JSONObject.NULL)
            if (stream != null) {
                val mimeType = contentResolver.getType(stream) ?: sharedIntent.type ?: "image/*"
                val extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType) ?: "bin"
                val relativePath = "$ATTACHMENT_DIRECTORY/$shareId.$extension"
                val destination = File(filesDir, relativePath)
                destination.parentFile?.mkdirs()
                storedImage = destination
                val input = contentResolver.openInputStream(stream) ?: throw IllegalStateException("unreadable stream")
                input.use { source ->
                    FileOutputStream(destination).use { sink ->
                        source.copyTo(sink)
                        sink.fd.sync()
                    }
                }
                json.put("attachment", JSONObject().put("relativePath", relativePath).put("mimeType", mimeType))
            } else {
                json.put("attachment", JSONObject.NULL)
            }

            val inbox = File(filesDir, INBOX_DIRECTORY)
            inbox.mkdirs()
            val temporary = File(inbox, "$shareId.json.tmp")
            FileOutputStream(temporary).use { sink ->
                sink.write(json.toString().toByteArray(Charsets.UTF_8))
                sink.fd.sync()
            }
            if (!temporary.renameTo(File(inbox, "$shareId.json"))) {
                temporary.delete()
                throw IllegalStateException("could not publish pending share")
            }
        } catch (error: Exception) {
            storedImage?.delete()
            throw error
        }
    }

    /**
     * Input contract: a shared stream must be a `content://` Uri served by another
     * app. Any other scheme, or a Uri on one of Jeeves' own providers, is refused
     * before anything is written.
     */
    private fun requireForeignContentUri(stream: Uri) {
        if (stream.scheme != ContentResolver.SCHEME_CONTENT) {
            throw SecurityException("only content:// streams are accepted")
        }
        val rawAuthority = stream.authority ?: throw SecurityException("stream has no authority")
        // A content Uri may carry a "userId@" prefix; providers are looked up by
        // the part after the last '@'.
        val authority = rawAuthority.substringAfterLast('@')
        // Own providers are enumerated rather than resolving the authority: another
        // app's provider may be invisible to us under package visibility rules.
        val ownProviders = packageManager
            .getPackageInfo(packageName, PackageManager.GET_PROVIDERS)
            .providers.orEmpty()
        val ownsAuthority = ownProviders.any { provider ->
            provider.authority?.split(';')?.any { it.equals(authority, ignoreCase = true) } == true
        }
        if (ownsAuthority) throw SecurityException("stream authority belongs to Jeeves")
    }

    @Suppress("DEPRECATION")
    private fun streamUri(sharedIntent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) {
            sharedIntent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            sharedIntent.getParcelableExtra(Intent.EXTRA_STREAM)
        }

    private companion object {
        const val INBOX_DIRECTORY = "share_inbox"
        const val ATTACHMENT_DIRECTORY = "capture_attachments"
    }
}
