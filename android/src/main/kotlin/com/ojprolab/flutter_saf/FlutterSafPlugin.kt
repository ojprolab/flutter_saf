package com.ojprolab.flutter_saf

import android.app.Activity
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
  private lateinit var channel : MethodChannel
  private var activity: Activity? = null
  private var pendingResult: MethodChannel.Result? = null
  private val REQUEST_CODE_PICK_DIRECTORY = 1001

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_saf")
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "pickDirectory" -> pickDirectory(result)
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
      return handlePickDirectory(requestCode, resultCode, data)
    }
    return false
  }

  private fun handlePickDirectory(requestCode: Int, resultCode: Int, data: Intent?): Boolean{
      if (resultCode == Activity.RESULT_OK && data != null) {
        val uri: Uri? = data.data
        if (uri != null) {
          activity?.contentResolver?.takePersistableUriPermission(
            uri,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
          )

          val documentFile = DocumentFile.fromTreeUri(activity!!, uri)
          val folderInfo = mapOf(
            "uri" to uri.toString(),
            "name" to (documentFile?.name ?: ""),
            "path" to uri.path
          )
          pendingResult?.success(folderInfo)
        } else {
          pendingResult?.error("INVALID_URI", "Selected URI is null", null)
        }
      } else {
        pendingResult?.error("CANCELLED", "User cancelled folder selection", null)
      }
      pendingResult = null
      return true
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
    binding.addActivityResultListener(this)
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
}
