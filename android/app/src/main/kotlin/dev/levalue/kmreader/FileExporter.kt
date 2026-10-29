package dev.levalue.kmreader

import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/** SAF grants access to just the destination selected by the user. */
class FileExporter(
    private val activity: FlutterFragmentActivity,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, "dev.levalue.kmreader/export")
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null
    private var source: File? = null
    @Volatile private var closed = false

    private val picker = activity.registerForActivityResult(
        ActivityResultContracts.CreateDocument("text/plain")
    ) { uri -> completeExport(uri) }
    private val imagePicker = activity.registerForActivityResult(
        ActivityResultContracts.CreateDocument("image/png")
    ) { uri -> completeExport(uri) }

    private fun completeExport(uri: Uri?) {
        val reply = pending ?: return
        val file = source
        if (uri == null || file == null) {
            pending = null
            source = null
            reply.success(false)
            return
        }
        executor.execute {
            var failure: Exception? = null
            try {
                file.inputStream().use { input ->
                    val output = activity.contentResolver.openOutputStream(uri, "wt")
                        ?: throw java.io.IOException("Cannot open the selected document.")
                    output.use {
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            if (closed) throw java.io.IOException("Export interrupted.")
                            val count = input.read(buffer)
                            if (count < 0) break
                            it.write(buffer, 0, count)
                        }
                    }
                }
            } catch (error: Exception) { failure = error }
            val error = failure
            main.post {
                if (!closed && pending === reply) {
                    pending = null
                    source = null
                    if (error == null) reply.success(true)
                    else reply.error("export_failed", "Unable to save the selected document.", null)
                }
            }
        }
    }

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "exportLog" && call.method != "exportImage") {
                result.notImplemented()
            } else if (closed || pending != null) {
                result.error("export_busy", "Another export is already active.", null)
            } else {
                try {
                    val path = call.argument<String>("path")
                        ?: throw IllegalArgumentException("Missing source.")
                    val file = File(path).canonicalFile
                    val roots = listOf(activity.filesDir, activity.cacheDir).map { it.canonicalFile }
                    require(file.isFile && roots.any { file.path.startsWith(it.path + File.separator) })
                    source = file
                    pending = result
                    val name = call.argument<String>("name") ?: "komga-server.log"
                    require(name.matches(Regex("[A-Za-z0-9._-]{1,80}")))
                    if (call.method == "exportImage") {
                        require(name.endsWith(".png"))
                        imagePicker.launch(name)
                    } else picker.launch(name)
                } catch (error: Exception) {
                    pending = null
                    source = null
                    result.error("export_failed", "Unable to open the document chooser.", null)
                }
            }
        }
    }

    fun close() {
        closed = true
        channel.setMethodCallHandler(null)
        pending?.error("export_interrupted", "The export window was closed.", null)
        pending = null
        source = null
        executor.shutdown()
        picker.unregister()
        imagePicker.unregister()
    }
}
