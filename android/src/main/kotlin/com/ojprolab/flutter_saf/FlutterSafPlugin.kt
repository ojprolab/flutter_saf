package com.ojprolab.flutter_saf

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.PluginRegistry

class FlutterSafPlugin: FlutterPlugin, MethodCallHandler, ActivityAware, PluginRegistry.ActivityResultListener {
  private lateinit var channel: MethodChannel
  private var activity: Activity? = null
  private var context: Context? = null
  private var pendingResult: MethodChannel.Result? = null
  private val REQUEST_CODE_PICK_DIRECTORY = 1001
  private val PREFS_NAME = "flutter_saf_prefs"
  private val KEY_PERSISTED_URIS = "persisted_uris"

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    context = flutterPluginBinding.applicationContext
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_saf")
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "pickDirectory" -> pickDirectory(result)
      "scanDirectory" -> scanDirectory(call, result)
      "readFileBytes" -> readFileBytes(call, result)
      else -> result.notImplemented()
    }
  }

  private fun pickDirectory(result: MethodChannel.Result) {
    if (activity == null) {
      result.error("NO_ACTIVITY", "Plugin not attached to activity", null)
      return
    }

    if (pendingResult != null) {
      result.error("ALREADY_ACTIVE", "Another pick operation is in progress", null)
      return
    }

    pendingResult = result

    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
      addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
      addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
      addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
    }

    activity?.startActivityForResult(intent, REQUEST_CODE_PICK_DIRECTORY)
  }

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
    if (requestCode == REQUEST_CODE_PICK_DIRECTORY) {
      if (resultCode == Activity.RESULT_OK && data != null) {
        val uri: Uri? = data.data
        if (uri != null) {
          try {
            val takeFlags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            activity?.contentResolver?.takePersistableUriPermission(uri, takeFlags)

            savePersistedUri(uri)

            val documentFile = DocumentFile.fromTreeUri(activity!!, uri)
            val directoryInfo = mapOf(
              "uri" to uri.toString(),
              "name" to (documentFile?.name ?: ""),
              "path" to uri.path
            )
            pendingResult?.success(directoryInfo)
          } catch (e: Exception) {
            pendingResult?.error("PERMISSION_ERROR", "Failed to persist URI permission: ${e.message}", null)
          }
        } else {
          pendingResult?.error("INVALID_URI", "Selected URI is null", null)
        }
      } else {
        pendingResult?.error("CANCELLED", "User cancelled directory selection", null)
      }
      pendingResult = null
      return true
    }
    return false
  }

  private fun scanDirectory(call: MethodCall, result: MethodChannel.Result) {
    val directoryUri = call.argument<String>("uri")
    val extensions = call.argument<List<String>>("extensions") ?: emptyList()
    val recursive = call.argument<Boolean>("recursive") ?: true

    if (directoryUri == null) {
      result.error("INVALID_ARGUMENTS", "directoryUri is required", null)
      return
    }

    try {
      val uri = Uri.parse(directoryUri)

      if (!hasPersistedPermission(uri)) {
        result.error("PERMISSION_DENIED", "No persisted permission for this URI", null)
        return
      }

      val documentFile = DocumentFile.fromTreeUri(activity!!, uri)

      if (documentFile == null || !documentFile.exists()) {
        result.error("INVALID_URI", "Directory does not exist or is invalid", null)
        return
      }

      val files = mutableListOf<Map<String, Any?>>()
      scanFiles(documentFile, extensions, recursive, files)
      result.success(files)
    } catch (e: SecurityException) {
      result.error("PERMISSION_ERROR", "Permission denied: ${e.message}", null)
    } catch (e: Exception) {
      result.error("SCAN_ERROR", "Error scanning directory: ${e.message}", null)
    }
  }

  private fun scanFiles(
    directory: DocumentFile,
    extensions: List<String>,
    recursive: Boolean,
    result: MutableList<Map<String, Any?>>
  ) {
    directory.listFiles().forEach { file ->
      if (file.isFile) {
        val shouldInclude = if (extensions.isEmpty()) {
          true
        } else {
          extensions.any { ext ->
            file.name?.endsWith(".$ext", ignoreCase = true) == true
          }
        }

        if (shouldInclude) {
          result.add(mapOf(
            "uri" to file.uri.toString(),
            "name" to file.name,
            "path" to file.uri.path,
            "size" to file.length(),
            "mimeType" to file.type,
            "lastModified" to file.lastModified()
          ))
        }
      } else if (file.isDirectory && recursive) {
        scanFiles(file, extensions, recursive, result)
      }
    }
  }

  private fun readFileBytes(call: MethodCall, result: MethodChannel.Result) {
    val fileUri = call.argument<String>("uri")

    if (fileUri == null) {
      result.error("INVALID_ARGUMENTS", "uri is required", null)
      return
    }

    try {
      val uri = Uri.parse(fileUri)
      val contentResolver = activity?.contentResolver

      if (contentResolver == null) {
        result.error("NO_CONTEXT", "Content resolver not available", null)
        return
      }

      contentResolver.openInputStream(uri)?.use { inputStream ->
        val bytes = inputStream.readBytes()
        result.success(bytes)
      } ?: result.error("READ_ERROR", "Failed to open input stream", null)

    } catch (e: SecurityException) {
      result.error("PERMISSION_ERROR", "Permission denied: ${e.message}", null)
    } catch (e: Exception) {
      result.error("READ_ERROR", "Error reading file: ${e.message}", null)
    }
  }

  private fun savePersistedUri(uri: Uri) {
    val prefs = context?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE) ?: return
    val existing = prefs.getStringSet(KEY_PERSISTED_URIS, mutableSetOf()) ?: mutableSetOf()
    val updated = existing.toMutableSet().apply { add(uri.toString()) }
    prefs.edit().putStringSet(KEY_PERSISTED_URIS, updated).apply()
  }

  private fun hasPersistedPermission(uri: Uri): Boolean {
    val contentResolver = activity?.contentResolver ?: return false
    val persistedUris = contentResolver.persistedUriPermissions
    return persistedUris.any { it.uri == uri }
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
    binding.addActivityResultListener(this)
    restorePersistedPermissions()
  }

  override fun onDetachedFromActivityForConfigChanges() {
    activity = null
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    activity = binding.activity
    binding.addActivityResultListener(this)
  }

  override fun onDetachedFromActivity() {
    activity = null
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }

  private fun restorePersistedPermissions() {
    val prefs = context?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE) ?: return
    val persistedUris = prefs.getStringSet(KEY_PERSISTED_URIS, emptySet()) ?: emptySet()
    val contentResolver = activity?.contentResolver ?: return

    val validUris = mutableSetOf<String>()
    persistedUris.forEach { uriString ->
      try {
        val uri = Uri.parse(uriString)
        if (contentResolver.persistedUriPermissions.any { it.uri == uri }) {
          validUris.add(uriString)
        }
      } catch (e: Exception) {
        // Skip invalid URIs
      }
    }

    prefs.edit().putStringSet(KEY_PERSISTED_URIS, validUris).apply()
  }
}
