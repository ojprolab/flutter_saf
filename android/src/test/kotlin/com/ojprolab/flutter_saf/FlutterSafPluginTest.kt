package com.ojprolab.flutter_saf

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.test.Test
import org.mockito.ArgumentMatchers.anyString
import org.mockito.ArgumentMatchers.eq
import org.mockito.ArgumentMatchers.isNull
import org.mockito.Mockito.mock
import org.mockito.Mockito.never
import org.mockito.Mockito.verify

internal class FlutterSafPluginTest {
  private fun call(method: String, args: Map<String, Any?>? = emptyMap()): MethodChannel.Result {
    val result = mock(MethodChannel.Result::class.java)
    FlutterSafPlugin().onMethodCall(MethodCall(method, args), result)
    return result
  }

  private fun assertInvalidArguments(method: String, args: Map<String, Any?>) {
    val result = call(method, args)
    verify(result).error(eq("INVALID_ARGUMENTS"), anyString(), isNull())
    verify(result, never()).success(org.mockito.ArgumentMatchers.any())
  }

  @Test
  fun unknownMethod_isNotImplemented() {
    val result = call("getPlatformVersion")

    verify(result).notImplemented()
  }

  @Test
  fun methodsRequiringUri_rejectMissingUri() {
    listOf(
      "scanDirectory",
      "readFileBytes",
      "readBytesAt",
      "copyFileToPath",
      "deleteFile",
      "renameFile",
      "getFileMetadata",
      "hashFile",
      "releasePermission",
    ).forEach { assertInvalidArguments(it, emptyMap()) }
  }

  @Test
  fun readBytesAt_rejectsMissingRange() {
    assertInvalidArguments("readBytesAt", mapOf("uri" to "content://doc/1", "size" to 10))
    assertInvalidArguments("readBytesAt", mapOf("uri" to "content://doc/1", "position" to 0))
  }

  @Test
  fun readBytesAt_acceptsLongPositions() {
    val result = call(
      "readBytesAt",
      mapOf("uri" to "content://doc/1", "position" to 5_000_000_000L, "size" to 10),
    )

    verify(result, never()).error(eq("INVALID_ARGUMENTS"), anyString(), isNull())
  }

  @Test
  fun copyFileToPath_rejectsMissingDestination() {
    assertInvalidArguments("copyFileToPath", mapOf("uri" to "content://doc/1"))
  }

  @Test
  fun renameFile_contentUriRequiresNewName() {
    assertInvalidArguments(
      "renameFile",
      mapOf("uri" to "content://doc/1", "destPath" to "/books/b.pdf"),
    )
  }

  @Test
  fun checkAccess_withoutUri_isFalseInsteadOfError() {
    val result = call("checkAccess")

    verify(result).success(false)
  }

  @Test
  fun checkAccess_beforeAttach_isFalseInsteadOfError() {
    val result = call("checkAccess", mapOf("uri" to "content://doc/1"))

    verify(result).success(false)
  }
}
