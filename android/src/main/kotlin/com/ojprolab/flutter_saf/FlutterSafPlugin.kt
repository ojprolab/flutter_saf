package com.ojprolab.flutter_saf

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.security.MessageDigest
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

class FlutterSafPlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware,
    PluginRegistry.ActivityResultListener {

    companion object {
        private const val METHOD_CHANNEL     = "flutter_saf"
        private const val REQUEST_PICK_DIR   = 1001
        private const val PREFS_NAME         = "flutter_saf_prefs"
        private const val KEY_PERSISTED_URIS = "persisted_uris"

        private val CHILD_PROJECTION = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            DocumentsContract.Document.COLUMN_FLAGS,
        )
    }

    private lateinit var methodChannel: MethodChannel

    private var activity: Activity? = null
    private var context:  Context?  = null
    private var pendingPickResult: MethodChannel.Result? = null

    private val executor = ThreadPoolExecutor(
        4, 4, 60L, TimeUnit.SECONDS,
        LinkedBlockingQueue(64),
        ThreadPoolExecutor.CallerRunsPolicy()
    )

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        executor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickDirectory"     -> pickDirectory(call, result)
            "scanDirectory"     -> scanDirectory(call, result)
            "readFileBytes"     -> readFileBytes(call, result)
            "readBytesAt"       -> readBytesAt(call, result)
            "copyFileToPath"    -> copyFileToPath(call, result)
            "checkAccess"       -> checkAccess(call, result)
            "deleteFile"        -> deleteFile(call, result)
            "renameFile"        -> renameFile(call, result)
            "exists"            -> exists(call, result)
            "getFileMetadata"   -> getFileMetadata(call, result)
            "hashFile"          -> hashFile(call, result)
            "releasePermission" -> releasePermission(call, result)
            else                -> result.notImplemented()
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
        pruneStaleBookmarks()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onDetachedFromActivity()                 { activity = null }

    // ── pickDirectory ─────────────────────────────────────────────────────────
    // Arguments: initialUri (String?)
    // Result:    { uri, name, path, bookmarkKey, storageType }
    // Errors:    NO_ACTIVITY | ALREADY_ACTIVE | PERMISSION_ERROR | INVALID_URI | CANCELLED

    private fun pickDirectory(call: MethodCall, result: MethodChannel.Result) {
        val act = activity ?: return result.error("NO_ACTIVITY", "Plugin not attached to an Activity", null)
        if (pendingPickResult != null) return result.error("ALREADY_ACTIVE", "Another pick is already in progress", null)

        pendingPickResult = result

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION  or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
            )
            call.argument<String>("initialUri")?.let { hint ->
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse(hint))
            }
        }
        act.startActivityForResult(intent, REQUEST_PICK_DIR)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK_DIR) return false

        val pending = pendingPickResult.also { pendingPickResult = null }

        if (resultCode != Activity.RESULT_OK || data == null) {
            pending?.error("CANCELLED", "User cancelled the folder picker", null)
            return true
        }

        val uri = data.data ?: run {
            pending?.error("INVALID_URI", "Selected URI was null", null)
            return true
        }

        try {
            val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            activity?.contentResolver?.takePersistableUriPermission(uri, flags)
            saveBookmark(uri)
            val name = DocumentFile.fromTreeUri(activity!!, uri)?.name ?: ""
            pending?.success(mapOf(
                "uri"         to uri.toString(),
                "name"        to name,
                "path"        to uri.path,
                "bookmarkKey" to uri.toString(),
                "storageType" to "android",
            ))
        } catch (e: Exception) {
            pending?.error("PERMISSION_ERROR", e.message, null)
        }
        return true
    }

    // ── scanDirectory ─────────────────────────────────────────────────────────
    // Arguments: uri*, extensions, recursive, taskId, includeHidden,
    //            minSize, maxSize, sortBy, sortDescending, limit
    // Progress:  { taskId, progress 0–1, status "scanning"|"done" }
    // Result:    List<{ uri, name, path, size, mimeType, lastModified, isWritable }>
    // Errors:    INVALID_ARGUMENTS | PERMISSION_DENIED | INVALID_URI | NO_CONTEXT | SCAN_ERROR

    private fun scanDirectory(call: MethodCall, result: MethodChannel.Result) {
        val directoryUri   = call.argument<String>("uri") ?: return result.error("INVALID_ARGUMENTS", "uri is required", null)
        val extensions     = call.argument<List<String>>("extensions") ?: emptyList()
        val recursive      = call.argument<Boolean>("recursive") ?: true
        val taskId         = call.argument<String>("taskId") ?: autoTaskId("scan")
        val includeHidden  = call.argument<Boolean>("includeHidden") ?: false
        val minSize        = (call.argument<Any>("minSize") as? Number)?.toLong()
        val maxSize        = (call.argument<Any>("maxSize") as? Number)?.toLong()
        val sortBy         = call.argument<String>("sortBy")
        val sortDescending = call.argument<Boolean>("sortDescending") ?: false
        val limit          = call.argument<Int>("limit")

        runInBackground {
            val treeUri = Uri.parse(directoryUri)

            if (!hasPersistedPermission(treeUri)) {
                return@runInBackground postToMain {
                    result.error("PERMISSION_DENIED", "No persisted permission for: $directoryUri", null)
                }
            }

            val rootDocId = runCatching { DocumentsContract.getTreeDocumentId(treeUri) }.getOrNull()
                ?: return@runInBackground postToMain {
                    result.error("INVALID_URI", "Cannot resolve document ID for: $directoryUri", null)
                }

            val ctx = appContext()
                ?: return@runInBackground postToMain { result.error("NO_CONTEXT", "Context unavailable", null) }

            try {
                val progress = ProgressReporter(taskId, "scanning")
                progress.report(0.0)
                val files = mutableListOf<Map<String, Any?>>()

                collectFilesCursor(
                    context       = ctx,
                    treeUri       = treeUri,
                    parentDocId   = rootDocId,
                    extensions    = extensions,
                    recursive     = recursive,
                    includeHidden = includeHidden,
                    minSize       = minSize,
                    maxSize       = maxSize,
                    accumulator   = files,
                    progress      = progress,
                    limit         = limit,
                )

                val sorted: List<Map<String, Any?>> = when (sortBy) {
                    "name"         -> files.sortedWith(compareBy<Map<String, Any?>> { it["name"] as? String }.let { if (sortDescending) it.reversed() else it })
                    "size"         -> files.sortedWith(compareBy<Map<String, Any?>> { it["size"] as? Long ?: 0L }.let { if (sortDescending) it.reversed() else it })
                    "lastModified" -> files.sortedWith(compareBy<Map<String, Any?>> { it["lastModified"] as? Long ?: 0L }.let { if (sortDescending) it.reversed() else it })
                    else           -> files
                }

                sendProgress(taskId, 1.0, "done")
                postToMain { result.success(sorted) }
            } catch (e: SecurityException) {
                postToMain { result.error("PERMISSION_DENIED", e.message, null) }
            } catch (e: Exception) {
                postToMain { result.error("SCAN_ERROR", e.message, null) }
            }
        }
    }

    private fun collectFilesCursor(
        context:       Context,
        treeUri:       Uri,
        parentDocId:   String,
        extensions:    List<String>,
        recursive:     Boolean,
        includeHidden: Boolean,
        minSize:       Long?,
        maxSize:       Long?,
        accumulator:   MutableList<Map<String, Any?>>,
        progress:      ProgressReporter,
        limit:         Int?,
    ) {
        if (limit != null && accumulator.size >= limit) return

        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocId)
        val cursor: Cursor = context.contentResolver.query(childrenUri, CHILD_PROJECTION, null, null, null) ?: return

        cursor.use { c ->
            val idCol    = c.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameCol  = c.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val sizeCol  = c.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE)
            val mimeCol  = c.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
            val modCol   = c.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
            val flagsCol = c.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_FLAGS)
            val total    = c.count.coerceAtLeast(1)

            while (c.moveToNext()) {
                if (limit != null && accumulator.size >= limit) break

                val name     = c.getString(nameCol) ?: continue
                val mimeType = c.getString(mimeCol) ?: ""
                val isDir    = mimeType == DocumentsContract.Document.MIME_TYPE_DIR

                if (!includeHidden && name.startsWith(".")) continue

                if (isDir) {
                    if (recursive) {
                        collectFilesCursor(
                            context, treeUri, c.getString(idCol),
                            extensions, true, includeHidden,
                            minSize, maxSize, accumulator, progress, limit
                        )
                    }
                } else {
                    val size = c.getLong(sizeCol)
                    if (minSize != null && size < minSize) continue
                    if (maxSize != null && size > maxSize) continue
                    if (!matchesExtension(name, extensions)) continue

                    val flags   = c.getInt(flagsCol)
                    val fileUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, c.getString(idCol))
                    accumulator.add(mapOf(
                        "uri"          to fileUri.toString(),
                        "name"         to name,
                        "path"         to fileUri.path,
                        "size"         to size,
                        "mimeType"     to mimeType,
                        "lastModified" to c.getLong(modCol),
                        "isWritable"   to ((flags and DocumentsContract.Document.FLAG_SUPPORTS_WRITE) != 0),
                    ))
                }

                progress.report((c.position + 1).toDouble() / total * 0.9)
            }
        }
    }

    // ── readFileBytes ─────────────────────────────────────────────────────────
    // Arguments: uri*, taskId, maxBytes
    // Progress:  { taskId, progress, status "reading"|"done" }
    // Result:    ByteArray
    // Errors:    INVALID_ARGUMENTS | NO_CONTEXT | READ_ERROR | OOM_ERROR |
    //            PERMISSION_ERROR | FILE_TOO_LARGE

    private fun readFileBytes(call: MethodCall, result: MethodChannel.Result) {
        val fileUri  = call.argument<String>("uri") ?: return result.error("INVALID_ARGUMENTS", "uri is required", null)
        val taskId   = call.argument<String>("taskId") ?: autoTaskId("read")
        val maxBytes = (call.argument<Any>("maxBytes") as? Number)?.toLong()

        runInBackground {
            val source = sourceFor(fileUri)
                ?: return@runInBackground postToMain { result.error("NO_CONTEXT", "ContentResolver unavailable", null) }

            try {
                val totalSize = source.size()

                if (maxBytes != null && totalSize > maxBytes) {
                    return@runInBackground postToMain {
                        result.error("FILE_TOO_LARGE", "File is $totalSize bytes, maxBytes is $maxBytes", null)
                    }
                }

                val progress = ProgressReporter(taskId, "reading")
                progress.report(0.0)

                val bytes = source.open()?.use { stream ->
                    val out    = java.io.ByteArrayOutputStream(if (totalSize > 0) totalSize.toInt() else 32768)
                    val buffer = ByteArray(32 * 1024)
                    var total  = 0L
                    var n: Int
                    while (stream.read(buffer).also { n = it } != -1) {
                        out.write(buffer, 0, n)
                        total += n
                        if (totalSize > 0) progress.report(total.toDouble() / totalSize)
                    }
                    out.toByteArray()
                } ?: return@runInBackground postToMain {
                    result.error("READ_ERROR", "Cannot open InputStream for: $fileUri", null)
                }

                sendProgress(taskId, 1.0, "done")
                postToMain { result.success(bytes) }
            } catch (e: OutOfMemoryError) {
                postToMain { result.error("OOM_ERROR", "File too large — use copyFileToPath instead", null) }
            } catch (e: SecurityException) {
                postToMain { result.error("PERMISSION_ERROR", e.message, null) }
            } catch (e: Exception) {
                postToMain { result.error("READ_ERROR", e.message, null) }
            }
        }
    }

    // ── readBytesAt ───────────────────────────────────────────────────────────────
    // Arguments: uri*, position (Long), size (Int)
    // Result:    ByteArray
    // Errors:    INVALID_ARGUMENTS | NO_CONTEXT | READ_ERROR | PERMISSION_ERROR

    private fun readBytesAt(call: MethodCall, result: MethodChannel.Result) {
        val fileUri  = call.argument<String>("uri") ?: return result.error("INVALID_ARGUMENTS", "uri is required", null)
        val position = (call.argument<Any>("position") as? Number)?.toLong() ?: return result.error("INVALID_ARGUMENTS", "position is required", null)
        val size     = (call.argument<Any>("size") as? Number)?.toInt()      ?: return result.error("INVALID_ARGUMENTS", "size is required", null)

        runInBackground {
            val source = sourceFor(fileUri)
                ?: return@runInBackground postToMain { result.error("NO_CONTEXT", "ContentResolver unavailable", null) }

            try {
                val bytes = readRangeSeeking(source, position, size)
                    ?: readRangeSkipping(source, position, size)
                    ?: return@runInBackground postToMain {
                        result.error("READ_ERROR", "Cannot open stream for: $fileUri", null)
                    }

                postToMain { result.success(bytes) }
            } catch (e: SecurityException) {
                postToMain { result.error("PERMISSION_ERROR", e.message, null) }
            } catch (e: Exception) {
                postToMain { result.error("READ_ERROR", e.message, null) }
            }
        }
    }

    private fun readRangeSeeking(source: Source, position: Long, size: Int): ByteArray? {
        val channel = source.openChannel() ?: return null
        return channel.use {
            if (runCatching { it.position(position) }.isFailure) return null
            val buffer = ByteBuffer.allocate(size)
            while (buffer.hasRemaining()) {
                if (it.read(buffer) <= 0) break
            }
            val bytes = buffer.array()
            if (buffer.position() == size) bytes else bytes.copyOf(buffer.position())
        }
    }

    private fun readRangeSkipping(source: Source, position: Long, size: Int): ByteArray? =
        source.open()?.use { s ->
            var remaining = position
            while (remaining > 0) {
                val skipped = s.skip(remaining)
                if (skipped <= 0) break
                remaining -= skipped
            }
            val buffer = ByteArray(size)
            var totalRead = 0
            while (totalRead < size) {
                val n = s.read(buffer, totalRead, size - totalRead)
                if (n == -1) break
                totalRead += n
            }
            if (totalRead == size) buffer else buffer.copyOf(totalRead)
        }

    // ── copyFileToPath ────────────────────────────────────────────────────────
    // Arguments: uri*, destPath*, taskId, overwrite, bufferSize
    // Progress:  { taskId, progress, status "copying"|"done" }
    // Result:    destPath string
    // Errors:    INVALID_ARGUMENTS | NO_CONTEXT | READ_ERROR | COPY_ERROR |
    //            OOM_ERROR | PERMISSION_ERROR | ALREADY_EXISTS

    private fun copyFileToPath(call: MethodCall, result: MethodChannel.Result) {
        val fileUri    = call.argument<String>("uri")      ?: return result.error("INVALID_ARGUMENTS", "uri is required", null)
        val destPath   = call.argument<String>("destPath") ?: return result.error("INVALID_ARGUMENTS", "destPath is required", null)
        val taskId     = call.argument<String>("taskId")   ?: autoTaskId("copy")
        val overwrite  = call.argument<Boolean>("overwrite") ?: true
        val bufferSize = (call.argument<Int>("bufferSize") ?: 32768).coerceAtLeast(1024)

        runInBackground {
            val source = sourceFor(fileUri)
                ?: return@runInBackground postToMain { result.error("NO_CONTEXT", "ContentResolver unavailable", null) }

            try {
                val destFile = File(destPath)
                if (!overwrite && destFile.exists()) {
                    return@runInBackground postToMain {
                        result.error("ALREADY_EXISTS", "Destination already exists: $destPath", null)
                    }
                }

                if (source.file?.canonicalFile == destFile.canonicalFile) {
                    return@runInBackground postToMain { result.success(destPath) }
                }

                destFile.parentFile?.mkdirs()

                val totalSize = source.size()

                val progress = ProgressReporter(taskId, "copying")
                progress.report(0.0)

                source.open()?.use { input ->
                    FileOutputStream(destFile).use { output ->
                        val buffer = ByteArray(bufferSize)
                        var copied = 0L
                        var n: Int
                        while (input.read(buffer).also { n = it } != -1) {
                            output.write(buffer, 0, n)
                            copied += n
                            if (totalSize > 0) progress.report(copied.toDouble() / totalSize)
                        }
                        output.flush()
                    }
                } ?: return@runInBackground postToMain {
                    result.error("READ_ERROR", "Cannot open InputStream for: $fileUri", null)
                }

                sendProgress(taskId, 1.0, "done")
                postToMain { result.success(destPath) }
            } catch (e: OutOfMemoryError) {
                postToMain { result.error("OOM_ERROR", "Out of memory during copy", null) }
            } catch (e: SecurityException) {
                postToMain { result.error("PERMISSION_ERROR", e.message, null) }
            } catch (e: Exception) {
                postToMain { result.error("COPY_ERROR", e.message, null) }
            }
        }
    }

    // ── checkAccess ───────────────────────────────────────────────────────────
    // Arguments: uri*
    // Result:    Boolean

    private fun checkAccess(call: MethodCall, result: MethodChannel.Result) {
        val uriString = call.argument<String>("uri") ?: return result.success(false)
        val ctx       = context ?: activity ?: return result.success(false)
        try {
            val uri = Uri.parse(uriString)
            val ok  = when {
                uri.scheme == "content" && DocumentsContract.isTreeUri(uri) ->
                    DocumentFile.fromTreeUri(ctx, uri)?.let { it.exists() && it.canRead() } ?: false
                uri.scheme == "content" ->
                    DocumentFile.fromSingleUri(ctx, uri)?.let { it.exists() && it.canRead() } ?: false
                else ->
                    File(uri.path ?: uriString).let { it.exists() && it.canRead() }
            }
            result.success(ok)
        } catch (e: Exception) {
            result.success(false)
        }
    }

    // ── deleteFile ────────────────────────────────────────────────────────────
    // Arguments: uri*
    // Result:    Boolean
    // Errors:    INVALID_ARGUMENTS | INVALID_URI | UNSUPPORTED | PERMISSION_ERROR | DELETE_ERROR

    private fun deleteFile(call: MethodCall, result: MethodChannel.Result) {
        val fileUri = call.argument<String>("uri") ?: return result.error("INVALID_ARGUMENTS", "uri is required", null)
        runInBackground {
            val ctx = appContext()
                ?: return@runInBackground postToMain { result.error("NO_CONTEXT", "Context unavailable", null) }

            try {
                val doc = DocumentFile.fromSingleUri(ctx, Uri.parse(fileUri))
                    ?: return@runInBackground postToMain { result.error("INVALID_URI", "Cannot resolve: $fileUri", null) }
                if (!doc.canWrite()) {
                    return@runInBackground postToMain { result.error("UNSUPPORTED", "File does not support deletion", null) }
                }
                postToMain { result.success(doc.delete()) }
            } catch (e: SecurityException) {
                postToMain { result.error("PERMISSION_ERROR", e.message, null) }
            } catch (e: Exception) {
                postToMain { result.error("DELETE_ERROR", e.message, null) }
            }
        }
    }

    // ── renameFile ────────────────────────────────────────────────────────────
    // Arguments: uri*, newName | destPath (file paths only; content URIs need newName)
    // Result:    new URI string for content URIs (may differ from original), new path for files
    // Errors:    INVALID_ARGUMENTS | NO_CONTEXT | INVALID_URI | UNSUPPORTED | PERMISSION_ERROR | RENAME_ERROR

    private fun renameFile(call: MethodCall, result: MethodChannel.Result) {
        val fileUri  = call.argument<String>("uri") ?: return result.error("INVALID_ARGUMENTS", "uri is required", null)
        val newName  = call.argument<String>("newName")
        val destPath = call.argument<String>("destPath")

        if (!isContentUri(fileUri)) return renameLocalFile(localFile(fileUri), newName, destPath, result)

        if (newName == null) return result.error("INVALID_ARGUMENTS", "newName is required for content URIs", null)
        runInBackground {
            val ctx = appContext()
                ?: return@runInBackground postToMain { result.error("NO_CONTEXT", "Context unavailable", null) }

            try {
                val doc = DocumentFile.fromSingleUri(ctx, Uri.parse(fileUri))
                    ?: return@runInBackground postToMain { result.error("INVALID_URI", "Cannot resolve: $fileUri", null) }
                if (!doc.canWrite()) {
                    return@runInBackground postToMain { result.error("UNSUPPORTED", "File does not support rename", null) }
                }
                if (doc.renameTo(newName)) {
                    postToMain { result.success(doc.uri.toString()) }
                } else {
                    postToMain { result.error("RENAME_ERROR", "Rename failed for: $fileUri", null) }
                }
            } catch (e: SecurityException) {
                postToMain { result.error("PERMISSION_ERROR", e.message, null) }
            } catch (e: Exception) {
                postToMain { result.error("RENAME_ERROR", e.message, null) }
            }
        }
    }

    private fun renameLocalFile(source: File, newName: String?, destPath: String?, result: MethodChannel.Result) {
        val dest = destPath?.let { File(it) }
            ?: newName?.let { File(source.parentFile, it) }
            ?: return result.error("INVALID_ARGUMENTS", "newName or destPath is required", null)

        runInBackground {
            try {
                if (source.renameTo(dest)) {
                    postToMain { result.success(dest.path) }
                } else {
                    postToMain { result.error("RENAME_ERROR", "Rename failed for: ${source.path}", null) }
                }
            } catch (e: SecurityException) {
                postToMain { result.error("PERMISSION_ERROR", e.message, null) }
            } catch (e: Exception) {
                postToMain { result.error("RENAME_ERROR", e.message, null) }
            }
        }
    }

    // ── exists ────────────────────────────────────────────────────────────────
    // Arguments: uri*
    // Result:    Boolean
    //
    // FIX: Must run on a background thread. DocumentFile.fromTreeUri().exists()
    // makes a ContentResolver query which can silently return null on the main
    // thread on some Android versions, producing false negatives for tree URIs.

    private fun exists(call: MethodCall, result: MethodChannel.Result) {
        val uriString = call.argument<String>("uri") ?: return result.success(false)
        val ctx       = context ?: activity ?: return result.success(false)

        runInBackground {
            try {
                val uri   = Uri.parse(uriString)
                val found = when {
                    uri.scheme == "content" && DocumentsContract.isTreeUri(uri) ->
                        DocumentFile.fromTreeUri(ctx, uri)?.exists() ?: false
                    uri.scheme == "content" ->
                        DocumentFile.fromSingleUri(ctx, uri)?.exists() ?: false
                    else ->
                        File(uri.path ?: uriString).exists()
                }
                postToMain { result.success(found) }
            } catch (e: Exception) {
                postToMain { result.success(false) }
            }
        }
    }

    // ── getFileMetadata ───────────────────────────────────────────────────────
    // Arguments: uri*
    // Result:    { uri, name, path, size, mimeType, lastModified, isWritable, isDirectory }
    // Errors:    INVALID_ARGUMENTS | NO_CONTEXT | INVALID_URI | METADATA_ERROR

    private fun getFileMetadata(call: MethodCall, result: MethodChannel.Result) {
        val fileUri = call.argument<String>("uri") ?: return result.error("INVALID_ARGUMENTS", "uri is required", null)
        runInBackground {
            try {
                if (!isContentUri(fileUri)) {
                    val file = localFile(fileUri)
                    if (!file.exists()) {
                        return@runInBackground postToMain { result.error("METADATA_ERROR", "File not found: $fileUri", null) }
                    }
                    val metadata = localMetadata(file)
                    return@runInBackground postToMain { result.success(metadata) }
                }

                val ctx = appContext()
                    ?: return@runInBackground postToMain { result.error("NO_CONTEXT", "Context unavailable", null) }
                val uri = Uri.parse(fileUri)
                val doc = if (DocumentsContract.isTreeUri(uri) && !DocumentsContract.isDocumentUri(ctx, uri)) {
                    DocumentFile.fromTreeUri(ctx, uri)
                } else {
                    DocumentFile.fromSingleUri(ctx, uri)
                } ?: return@runInBackground postToMain { result.error("INVALID_URI", "Cannot resolve: $fileUri", null) }

                val metadata = mapOf(
                    "uri"          to doc.uri.toString(),
                    "name"         to doc.name,
                    "path"         to doc.uri.path,
                    "size"         to doc.length(),
                    "mimeType"     to doc.type,
                    "lastModified" to doc.lastModified(),
                    "isWritable"   to doc.canWrite(),
                    "isDirectory"  to doc.isDirectory,
                )
                postToMain { result.success(metadata) }
            } catch (e: Exception) {
                postToMain { result.error("METADATA_ERROR", e.message, null) }
            }
        }
    }

    private fun localMetadata(file: File): Map<String, Any?> = mapOf(
        "uri"          to Uri.fromFile(file).toString(),
        "name"         to file.name,
        "path"         to file.path,
        "size"         to file.length(),
        "mimeType"     to if (file.isDirectory) null else MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()),
        "lastModified" to file.lastModified(),
        "isWritable"   to file.canWrite(),
        "isDirectory"  to file.isDirectory,
    )

    private fun hashFile(call: MethodCall, result: MethodChannel.Result) {
        val fileUri = call.argument<String>("uri") ?: return result.error("INVALID_ARGUMENTS", "uri is required", null)

        runInBackground {
            val source = sourceFor(fileUri)
                ?: return@runInBackground postToMain { result.error("NO_CONTEXT", "ContentResolver unavailable", null) }

            try {
                val digest = MessageDigest.getInstance("SHA-256")
                source.open()?.use { input ->
                    val buffer = ByteArray(64 * 1024)
                    var n: Int
                    while (input.read(buffer).also { n = it } != -1) digest.update(buffer, 0, n)
                } ?: return@runInBackground postToMain {
                    result.error("READ_ERROR", "Cannot open InputStream for: $fileUri", null)
                }

                val hex = digest.digest().joinToString("") { "%02x".format(it) }
                postToMain { result.success(hex) }
            } catch (e: SecurityException) {
                postToMain { result.error("PERMISSION_ERROR", e.message, null) }
            } catch (e: Exception) {
                postToMain { result.error("READ_ERROR", e.message, null) }
            }
        }
    }

    // ── releasePermission ─────────────────────────────────────────────────────
    // Arguments: uri*
    // Result:    Boolean
    // Errors:    INVALID_ARGUMENTS | RELEASE_ERROR

    private fun releasePermission(call: MethodCall, result: MethodChannel.Result) {
        val uriString = call.argument<String>("uri") ?: return result.error("INVALID_ARGUMENTS", "uri is required", null)
        try {
            val uri   = Uri.parse(uriString)
            val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            appContext()?.contentResolver?.releasePersistableUriPermission(uri, flags)
            removeBookmark(uri)
            result.success(true)
        } catch (e: Exception) {
            result.error("RELEASE_ERROR", e.message, null)
        }
    }

    // ── Bookmarks ─────────────────────────────────────────────────────────────

    private fun saveBookmark(uri: Uri) {
        val prefs    = context?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE) ?: return
        val existing = prefs.getStringSet(KEY_PERSISTED_URIS, emptySet()) ?: emptySet()
        prefs.edit().putStringSet(KEY_PERSISTED_URIS, existing + uri.toString()).apply()
    }

    private fun removeBookmark(uri: Uri) {
        val prefs    = context?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE) ?: return
        val existing = prefs.getStringSet(KEY_PERSISTED_URIS, emptySet()) ?: emptySet()
        prefs.edit().putStringSet(KEY_PERSISTED_URIS, existing - uri.toString()).apply()
    }

    private fun hasPersistedPermission(uri: Uri): Boolean =
        appContext()?.contentResolver?.persistedUriPermissions?.any { it.uri == uri } == true

    private fun pruneStaleBookmarks() {
        val prefs   = context?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE) ?: return
        val cr      = appContext()?.contentResolver ?: return
        val granted = cr.persistedUriPermissions.map { it.uri.toString() }.toSet()
        val stored  = prefs.getStringSet(KEY_PERSISTED_URIS, emptySet()) ?: emptySet()
        val valid   = stored.intersect(granted)
        if (valid.size != stored.size) prefs.edit().putStringSet(KEY_PERSISTED_URIS, valid).apply()
    }

    // ── Utilities ─────────────────────────────────────────────────────────────

    private class Source(
        val file:        File?,
        val open:        () -> InputStream?,
        val openChannel: () -> FileChannel?,
        val size:        () -> Long,
    )

    private inner class ProgressReporter(private val taskId: String, private val status: String) {
        private var lastPercent = -1

        fun report(progress: Double) {
            val percent = (progress * 100).toInt()
            if (percent == lastPercent) return
            lastPercent = percent
            sendProgress(taskId, progress, status)
        }
    }

    private fun appContext(): Context? = context ?: activity

    private fun isContentUri(raw: String) = raw.startsWith("content://")

    private fun localFile(raw: String): File =
        if (raw.startsWith("file://")) File(Uri.parse(raw)?.path ?: raw.removePrefix("file://")) else File(raw)

    private fun sourceFor(raw: String): Source? {
        if (!isContentUri(raw)) {
            val file = localFile(raw)
            return Source(
                file        = file,
                open        = { FileInputStream(file) },
                openChannel = { RandomAccessFile(file, "r").channel },
                size        = { file.length() },
            )
        }
        val cr  = appContext()?.contentResolver ?: return null
        val uri = Uri.parse(raw)
        return Source(
            file        = null,
            open        = { cr.openInputStream(uri) },
            openChannel = {
                runCatching { cr.openFileDescriptor(uri, "r") }.getOrNull()
                    ?.let { ParcelFileDescriptor.AutoCloseInputStream(it).channel }
            },
            size        = { runCatching { cr.openFileDescriptor(uri, "r")?.use { it.statSize } }.getOrNull() ?: -1L },
        )
    }

    private fun runInBackground(block: () -> Unit) = executor.execute(block)

    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private fun postToMain(block: () -> Unit) {
        mainHandler.post(block)
    }

    // Combined channel: progress is pushed to Dart via invokeMethod("onProgress", …)
    // on the same MethodChannel used for all other calls. No separate EventChannel needed.
    private fun sendProgress(taskId: String, progress: Double, status: String) {
        postToMain {
            methodChannel.invokeMethod("onProgress", mapOf(
                "taskId"   to taskId,
                "progress" to progress,
                "status"   to status,
            ))
        }
    }

    private fun matchesExtension(name: String, extensions: List<String>): Boolean {
        if (extensions.isEmpty()) return true
        val lower = name.lowercase()
        return extensions.any { lower.endsWith(".${it.lowercase()}") }
    }

    private fun autoTaskId(prefix: String) = "${prefix}_${System.currentTimeMillis()}"
}
