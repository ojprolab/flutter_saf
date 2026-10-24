package com.ojprolab.flutter_saf

import android.content.Context
import android.net.Uri
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.Mockito.mock
import org.mockito.Mockito.mockingDetails
import org.mockito.Mockito.`when`
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class FlutterSafPluginFileTest {
  private class Reply : MethodChannel.Result {
    @Volatile var done = false
    var value: Any? = null
    var errorCode: String? = null

    override fun success(result: Any?) {
      value = result
      done = true
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
      this.errorCode = errorCode
      done = true
    }

    override fun notImplemented() {
      done = true
    }
  }

  private val abcSha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

  private lateinit var binding: FlutterPlugin.FlutterPluginBinding
  private lateinit var messenger: BinaryMessenger
  private lateinit var plugin: FlutterSafPlugin
  private lateinit var dir: File

  @Before
  fun setUp() {
    val context = ApplicationProvider.getApplicationContext<Context>()
    Robolectric.setupContentProvider(TestDocumentProvider::class.java, TestDocumentProvider.AUTHORITY)
    TestDocumentProvider.files.clear()
    dir = File(context.cacheDir, "flutter_saf_test").apply {
      deleteRecursively()
      mkdirs()
    }

    binding = mock(FlutterPlugin.FlutterPluginBinding::class.java)
    `when`(binding.applicationContext).thenReturn(context)
    messenger = mock(BinaryMessenger::class.java)
    `when`(binding.binaryMessenger).thenReturn(messenger)
    plugin = FlutterSafPlugin().also { it.onAttachedToEngine(binding) }
  }

  @After
  fun tearDown() {
    plugin.onDetachedFromEngine(binding)
    dir.deleteRecursively()
  }

  private fun invoke(method: String, args: Map<String, Any?>): Reply {
    val reply = Reply()
    plugin.onMethodCall(MethodCall(method, args), reply)
    val deadline = System.currentTimeMillis() + 5_000
    while (!reply.done && System.currentTimeMillis() < deadline) {
      shadowOf(Looper.getMainLooper()).idle()
      Thread.sleep(5)
    }
    assertTrue(reply.done, "$method never replied")
    return reply
  }

  private fun file(name: String, bytes: ByteArray) = File(dir, name).apply { writeBytes(bytes) }

  private fun sharedDocument(id: String, bytes: ByteArray): String {
    TestDocumentProvider.files[id] = file("shared_$id.pdf", bytes)
    return TestDocumentProvider.uriFor(id).toString()
  }

  private val sample = ByteArray(100) { it.toByte() }

  @Test
  fun readBytesAt_contentUriWithoutActivity_readsTheRange() {
    val uri = sharedDocument("1", sample)

    val reply = invoke("readBytesAt", mapOf("uri" to uri, "position" to 10L, "size" to 5))

    assertNull(reply.errorCode)
    assertContentEquals(sample.copyOfRange(10, 15), reply.value as ByteArray)
  }

  @Test
  fun readBytesAt_plainPathWithReservedCharacters_readsTheFile() {
    val source = file("a#1 b.pdf", sample)

    val reply = invoke("readBytesAt", mapOf("uri" to source.path, "position" to 0L, "size" to 3))

    assertContentEquals(byteArrayOf(0, 1, 2), reply.value as ByteArray)
  }

  @Test
  fun readFileBytes_contentUriWithoutActivity_readsEverything() {
    val uri = sharedDocument("1", sample)

    val reply = invoke("readFileBytes", mapOf("uri" to uri))

    assertContentEquals(sample, reply.value as ByteArray)
  }

  @Test
  fun copyFileToPath_contentUriWithoutActivity_copiesTheBytes() {
    val uri = sharedDocument("1", sample)
    val dest = File(dir, "copies/book.pdf")

    val reply = invoke("copyFileToPath", mapOf("uri" to uri, "destPath" to dest.path))

    assertEquals(dest.path, reply.value)
    assertContentEquals(sample, dest.readBytes())
  }

  @Test
  fun copyFileToPath_acceptsPlainPathsAndFileUris() {
    val source = file("a#1 b.pdf", sample)
    val fromPath = File(dir, "from_path.pdf")
    val fromFileUri = File(dir, "from_file_uri.pdf")

    invoke("copyFileToPath", mapOf("uri" to source.path, "destPath" to fromPath.path))
    invoke("copyFileToPath", mapOf("uri" to Uri.fromFile(source).toString(), "destPath" to fromFileUri.path))

    assertContentEquals(sample, fromPath.readBytes())
    assertContentEquals(sample, fromFileUri.readBytes())
  }

  @Test
  fun copyFileToPath_ontoItself_keepsTheFile() {
    val source = file("book.pdf", sample)

    val reply = invoke("copyFileToPath", mapOf("uri" to source.path, "destPath" to source.path))

    assertEquals(source.path, reply.value)
    assertContentEquals(sample, source.readBytes())
  }

  @Test
  fun hashFile_isSha256HexForPathsFileUrisAndContentUris() {
    val abc = "abc".toByteArray()
    val source = file("abc.txt", abc)

    listOf(source.path, Uri.fromFile(source).toString(), sharedDocument("1", abc)).forEach { uri ->
      assertEquals(abcSha256, invoke("hashFile", mapOf("uri" to uri)).value, uri)
    }
  }

  @Test
  fun hashFile_missingFile_isReadError() {
    val reply = invoke("hashFile", mapOf("uri" to File(dir, "missing.pdf").path))

    assertEquals("READ_ERROR", reply.errorCode)
  }

  @Test
  fun getFileMetadata_plainPath_describesFilesAndDirectories() {
    val source = file("book.pdf", sample)

    @Suppress("UNCHECKED_CAST")
    val fileMeta = invoke("getFileMetadata", mapOf("uri" to source.path)).value as Map<String, Any?>
    @Suppress("UNCHECKED_CAST")
    val dirMeta = invoke("getFileMetadata", mapOf("uri" to dir.path)).value as Map<String, Any?>

    assertEquals("book.pdf", fileMeta["name"])
    assertEquals(100L, fileMeta["size"])
    assertEquals(false, fileMeta["isDirectory"])
    assertEquals(true, dirMeta["isDirectory"])
  }

  @Test
  fun getFileMetadata_missingPath_isError() {
    val reply = invoke("getFileMetadata", mapOf("uri" to File(dir, "missing.pdf").path))

    assertEquals("METADATA_ERROR", reply.errorCode)
  }

  @Test
  fun getFileMetadata_contentUriWithoutActivity_readsNameAndSize() {
    val uri = sharedDocument("1", sample)

    @Suppress("UNCHECKED_CAST")
    val meta = invoke("getFileMetadata", mapOf("uri" to uri)).value as Map<String, Any?>

    assertEquals("shared_1.pdf", meta["name"])
    assertEquals(100L, meta["size"])
  }

  @Test
  fun renameFile_plainPath_acceptsDestPathOrNewName() {
    val source = file("a.pdf", sample)
    val moved = File(dir, "b.pdf")

    val byDest = invoke("renameFile", mapOf("uri" to source.path, "destPath" to moved.path))
    val byName = invoke("renameFile", mapOf("uri" to moved.path, "newName" to "c.pdf"))

    assertEquals(moved.path, byDest.value)
    assertEquals(File(dir, "c.pdf").path, byName.value)
    assertFalse(source.exists())
    assertContentEquals(sample, File(dir, "c.pdf").readBytes())
  }

  @Test
  fun readBytesAt_seeksToAnyOffsetAndShortReadsAtTheEnd() {
    val large = ByteArray(1 shl 20) { (it * 31).toByte() }
    val path = file("large.pdf", large).path
    val uri = sharedDocument("large", large)

    listOf(path, uri).forEach { source ->
      listOf(0L, 4096L, 700_001L).forEach { position ->
        val reply = invoke("readBytesAt", mapOf("uri" to source, "position" to position, "size" to 100))
        val from = position.toInt()
        assertContentEquals(large.copyOfRange(from, from + 100), reply.value as ByteArray, "$source@$position")
      }
      val tail = invoke("readBytesAt", mapOf("uri" to source, "position" to large.size - 10L, "size" to 100))
      assertContentEquals(large.copyOfRange(large.size - 10, large.size), tail.value as ByteArray)
      val past = invoke("readBytesAt", mapOf("uri" to source, "position" to large.size + 10L, "size" to 100))
      assertEquals(0, (past.value as ByteArray).size)
    }
  }

  @Test
  fun copyFileToPath_sendsAtMostOneProgressEventPerPercent() {
    val source = file("large.pdf", ByteArray(1 shl 20))

    invoke(
      "copyFileToPath",
      mapOf("uri" to source.path, "destPath" to File(dir, "copy.pdf").path, "bufferSize" to 1024),
    )

    val sends = mockingDetails(messenger).invocations.count { it.method.name == "send" }
    assertTrue(sends in 2..102, "sent $sends progress events for 1024 chunks")
  }
}
