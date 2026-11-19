package loonyb.`in`.jeeves

import android.app.Activity
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.concurrent.Executors

/**
 * File access for the folder plugins, over the system folder picker.
 *
 * Channel: "jeeves/folder". `tree` is the persisted tree URI the picker returned;
 * `path` is a `/`-separated path relative to it ("" is the folder itself).
 *
 *   pickFolder() -> String?                         tree URI, null if cancelled
 *   listDirectories({tree, path}) -> List<String>
 *   listFiles({tree, path}) -> List<String>
 *   length({tree, path}) -> Long?                   null if it does not exist
 *   read({tree, path, offset, maxBytes}) -> ByteArray
 *   append({tree, path, bytes}) -> null             creates the file if needed
 *   createIfAbsent({tree, path, bytes}) -> Boolean
 *   writeAtomically({tree, path, bytes}) -> null    replaces the file
 *   remove({tree, path}) -> null                    deletes the file, if it is there
 *
 * The last two are the vault's: it rewrites a whole page and must not leave a
 * half-written one behind, and it removes a page file that has no page in it
 * any more.
 *
 * No new dependency: the framework's DocumentsContract is enough. All work runs on
 * one background thread, in call order, so an append never overtakes a read.
 */
class FolderStoragePlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPick: MethodChannel.Result? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private companion object {
        const val CHANNEL = "jeeves/folder"
        const val PICK_REQUEST_CODE = 0x4A46
        const val BINARY_MIME = "application/octet-stream"
    }

    // ---- FlutterPlugin ----------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    // ---- ActivityAware ----------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
    }

    // ---- Picker -----------------------------------------------------------

    private fun pickFolder(result: MethodChannel.Result) {
        val binding = activityBinding
        if (binding == null || pendingPick != null) {
            result.error("unavailable", "No activity to show the folder picker", null)
            return
        }
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
        )
        binding.activity.startActivityForResult(intent, PICK_REQUEST_CODE)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_REQUEST_CODE) return false
        val result = pendingPick ?: return true
        pendingPick = null
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) {
            result.success(null)
            return true
        }
        appContext.contentResolver.takePersistableUriPermission(
            tree,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
        )
        result.success(tree.toString())
        return true
    }

    // ---- MethodCallHandler ------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "pickFolder") {
            pickFolder(result)
            return
        }
        val tree = call.argument<String>("tree")
        val path = call.argument<String>("path") ?: ""
        if (tree == null) {
            result.error("bad_arguments", "tree is required", null)
            return
        }
        worker.execute {
            try {
                val value: Any? = handle(call, Uri.parse(tree), path)
                mainHandler.post { result.success(value) }
            } catch (error: Exception) {
                mainHandler.post { result.error("io_error", error.message, null) }
            }
        }
    }

    private fun handle(call: MethodCall, tree: Uri, path: String): Any? = when (call.method) {
        "listDirectories" -> children(tree, path).filter { it.isDirectory }.map { it.name }
        "listFiles" -> children(tree, path).filter { !it.isDirectory }.map { it.name }
        "length" -> resolve(tree, path)?.let { sizeOf(it) }
        "read" -> read(
            tree,
            path,
            (call.argument<Number>("offset") ?: 0).toLong(),
            (call.argument<Number>("maxBytes") ?: 0).toInt(),
        )
        "append" -> {
            append(tree, path, call.argument<ByteArray>("bytes") ?: ByteArray(0))
            null
        }
        "createIfAbsent" -> createIfAbsent(tree, path, call.argument<ByteArray>("bytes") ?: ByteArray(0))
        "writeAtomically" -> {
            writeAtomically(tree, path, call.argument<ByteArray>("bytes") ?: ByteArray(0))
            null
        }
        "remove" -> {
            remove(tree, path)
            null
        }
        else -> throw IllegalArgumentException("unknown method ${call.method}")
    }

    // ---- Documents --------------------------------------------------------

    private class Child(val documentId: String, val name: String, val isDirectory: Boolean)

    private val resolver: ContentResolver get() = appContext.contentResolver

    private fun children(tree: Uri, path: String): List<Child> {
        val parentId = documentIdOf(tree, path) ?: return emptyList()
        return childrenOfId(tree, parentId)
    }

    private fun childrenOfId(tree: Uri, parentId: String): List<Child> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
        val out = mutableListOf<Child>()
        resolver.query(
            uri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                out.add(
                    Child(
                        cursor.getString(0),
                        cursor.getString(1),
                        cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR,
                    ),
                )
            }
        }
        return out
    }

    private fun documentIdOf(tree: Uri, path: String): String? {
        var id = DocumentsContract.getTreeDocumentId(tree)
        if (path.isEmpty()) return id
        for (part in path.split('/')) {
            id = childrenOfId(tree, id).firstOrNull { it.name == part }?.documentId ?: return null
        }
        return id
    }

    private fun resolve(tree: Uri, path: String): Uri? =
        documentIdOf(tree, path)?.let { DocumentsContract.buildDocumentUriUsingTree(tree, it) }

    private fun sizeOf(document: Uri): Long? =
        resolver.query(document, arrayOf(DocumentsContract.Document.COLUMN_SIZE), null, null, null)
            ?.use { cursor -> if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getLong(0) else null }

    /**
     * The bytes of the document at [path], from [offset] and at most [maxBytes].
     *
     * The descriptor behind a document need not be seekable: Android lets a
     * provider hand back a pipe, and a pipe has no size and no position. So the
     * bytes are read in sequence and the offset is skipped, rather than sought
     * to, which reads the same bytes from a file and from a pipe.
     */
    private fun read(tree: Uri, path: String, offset: Long, maxBytes: Int): ByteArray {
        val document = resolve(tree, path) ?: return ByteArray(0)
        if (maxBytes <= 0) return ByteArray(0)
        val stream = resolver.openInputStream(document) ?: return ByteArray(0)
        return stream.use {
            skip(it, offset)
            readUpTo(it, maxBytes.toLong())
        }
    }

    /** Read up to [limit] bytes from [stream], to the end of it. */
    private fun readUpTo(stream: InputStream, limit: Long): ByteArray {
        val out = ByteArrayOutputStream()
        val chunk = ByteArray(8192)
        var remaining = limit
        while (remaining > 0) {
            val wanted = minOf(chunk.size.toLong(), remaining).toInt()
            val read = stream.read(chunk, 0, wanted)
            if (read < 0) break
            out.write(chunk, 0, read)
            remaining -= read
        }
        return out.toByteArray()
    }

    /** Skip [count] bytes of [stream], reading them if it cannot seek. */
    private fun skip(stream: InputStream, count: Long) {
        var remaining = count
        val scratch = ByteArray(8192)
        while (remaining > 0) {
            val wanted = minOf(scratch.size.toLong(), remaining).toInt()
            val read = stream.read(scratch, 0, wanted)
            if (read < 0) return
            remaining -= read
        }
    }

    /** The directory document for [path], creating each missing level. */
    private fun ensureDirectory(tree: Uri, path: String): String {
        var id = DocumentsContract.getTreeDocumentId(tree)
        if (path.isEmpty()) return id
        for (part in path.split('/')) {
            val existing = childrenOfId(tree, id).firstOrNull { it.name == part }
            id = if (existing != null) {
                existing.documentId
            } else {
                val parent = DocumentsContract.buildDocumentUriUsingTree(tree, id)
                val created = DocumentsContract.createDocument(
                    resolver,
                    parent,
                    DocumentsContract.Document.MIME_TYPE_DIR,
                    part,
                ) ?: throw java.io.IOException("could not create $part")
                DocumentsContract.getDocumentId(created)
            }
        }
        return id
    }

    private fun createFile(tree: Uri, path: String): Uri {
        val slash = path.lastIndexOf('/')
        val directory = if (slash < 0) "" else path.substring(0, slash)
        val name = path.substring(slash + 1)
        val parentId = ensureDirectory(tree, directory)
        val parent = DocumentsContract.buildDocumentUriUsingTree(tree, parentId)
        val created = DocumentsContract.createDocument(resolver, parent, BINARY_MIME, name)
            ?: throw java.io.IOException("could not create $name")
        // Providers rename on a collision ("name (1)"); a file the other devices
        // cannot find by name is worse than a failed write.
        val actual = resolver.query(
            created,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { if (it.moveToFirst()) it.getString(0) else null }
        if (actual != name) {
            DocumentsContract.deleteDocument(resolver, created)
            throw java.io.IOException("the storage provider renamed $name to $actual")
        }
        return created
    }

    private fun append(tree: Uri, path: String, bytes: ByteArray) {
        val document = resolve(tree, path) ?: createFile(tree, path)
        resolver.openOutputStream(document, "wa")?.use {
            it.write(bytes)
            it.flush()
        } ?: throw java.io.IOException("could not open $path for append")
    }

    private fun createIfAbsent(tree: Uri, path: String, bytes: ByteArray): Boolean {
        if (resolve(tree, path) != null) return false
        val document = createFile(tree, path)
        resolver.openOutputStream(document, "w")?.use {
            it.write(bytes)
            it.flush()
        } ?: throw java.io.IOException("could not open $path for writing")
        return true
    }

    /**
     * Replace the file at [path] with [bytes], through a temporary file and a
     * rename.
     *
     * The document tree has no atomic replace: a document is written by opening
     * it, and a rename is the only way one document takes another's place. So
     * the bytes go to a sibling temporary document and that document is renamed
     * onto the page's name. A provider that refuses a rename onto a name that
     * is taken gets the old page deleted first — and for that moment the page
     * is not there. The vault reads a missing page as "nothing to read", never
     * as a deletion, and compares what it finds with its own copy of the page,
     * so the gap costs a rescan and nothing else.
     *
     * A provider that renames on a collision would leave the page under another
     * name, which is worse than a failed write: the name is checked, and the
     * write fails loudly instead.
     */
    private fun writeAtomically(tree: Uri, path: String, bytes: ByteArray) {
        val slash = path.lastIndexOf('/')
        val directory = if (slash < 0) "" else path.substring(0, slash)
        val name = path.substring(slash + 1)
        val temporaryName = "$name.jeeves-tmp"
        // A temporary file left behind by an earlier crash would collide with
        // the one written below.
        deleteChild(tree, directory, temporaryName)
        val temporary = createFile(tree, if (directory.isEmpty()) temporaryName else "$directory/$temporaryName")
        resolver.openOutputStream(temporary, "w")?.use {
            it.write(bytes)
            it.flush()
        } ?: throw java.io.IOException("could not open $path for writing")
        val renamed = DocumentsContract.renameDocument(resolver, temporary, name)
            ?: run {
                // The provider will not rename onto a name that is taken: the
                // old page goes first, and the page is briefly not there.
                deleteChild(tree, directory, name)
                DocumentsContract.renameDocument(resolver, temporary, name)
                    ?: throw java.io.IOException("could not rename $temporaryName to $name")
            }
        val actual = displayName(renamed)
        if (actual != name) {
            throw java.io.IOException("the storage provider renamed $name to $actual")
        }
    }

    /** Delete the file at [path]. A file that is not there is not an error. */
    private fun remove(tree: Uri, path: String) {
        val document = resolve(tree, path) ?: return
        DocumentsContract.deleteDocument(resolver, document)
    }

    /** Delete the child of [directory] called [name], if it is there. */
    private fun deleteChild(tree: Uri, directory: String, name: String) {
        val parentId = documentIdOf(tree, directory) ?: return
        val child = childrenOfId(tree, parentId).firstOrNull { it.name == name } ?: return
        DocumentsContract.deleteDocument(
            resolver,
            DocumentsContract.buildDocumentUriUsingTree(tree, child.documentId),
        )
    }

    /** The name a document is known by, or null when it cannot be read. */
    private fun displayName(document: Uri): String? =
        resolver.query(
            document,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { if (it.moveToFirst()) it.getString(0) else null }
}
