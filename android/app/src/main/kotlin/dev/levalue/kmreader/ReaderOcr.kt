package dev.levalue.kmreader

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import androidx.exifinterface.media.ExifInterface
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
import com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
import com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/** Bundled ML Kit recognizers run offline; images never leave the device. */
class ReaderOcr(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "dev.levalue.kmreader/ocr")
    private val executor = Executors.newSingleThreadExecutor()
    private val clients = mutableMapOf<String, TextRecognizer>()
    @Volatile private var closed = false
    private var busy = false

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "capabilities" -> result.success(mapOf("languages" to listOf("latin", "ja", "zh", "ko", "hi"), "offline" to true))
                "recognize" -> {
                    val path = call.argument<String>("path")
                    val language = call.argument<String>("language") ?: "latin"
                    if (path == null || !File(path).isFile || File(path).length() > 32L * 1024 * 1024) {
                        result.error("invalid_image", "Choose an image smaller than 32 MiB.", null)
                    } else if (busy) {
                        result.error("busy", "Text recognition is already running.", null)
                    } else {
                        busy = true
                        executor.execute { recognize(path, language, result) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun recognize(path: String, language: String, result: MethodChannel.Result) {
        var bitmap: Bitmap? = null
        try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 4096) sample *= 2
            bitmap = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
                ?: throw IllegalArgumentException("Unsupported image.")
            val transform = Matrix()
            when (ExifInterface(path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                ExifInterface.ORIENTATION_ROTATE_90 -> transform.postRotate(90f)
                ExifInterface.ORIENTATION_ROTATE_180 -> transform.postRotate(180f)
                ExifInterface.ORIENTATION_ROTATE_270 -> transform.postRotate(270f)
                ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> transform.postScale(-1f, 1f)
                ExifInterface.ORIENTATION_FLIP_VERTICAL -> transform.postScale(1f, -1f)
                ExifInterface.ORIENTATION_TRANSPOSE -> { transform.postRotate(90f); transform.postScale(-1f, 1f) }
                ExifInterface.ORIENTATION_TRANSVERSE -> { transform.postRotate(270f); transform.postScale(-1f, 1f) }
            }
            if (!transform.isIdentity) {
                val rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, transform, true)
                if (rotated !== bitmap) bitmap.recycle()
                bitmap = rotated
            }
            val image = bitmap
            if (closed) { image.recycle(); return }
            val script = when {
                language.startsWith("ja") -> "ja"
                language.startsWith("zh") -> "zh"
                language.startsWith("ko") -> "ko"
                language.startsWith("hi") -> "hi"
                else -> "latin"
            }
            val recognizer = synchronized(clients) {
              if (closed) throw IllegalStateException("Reader closed.")
              clients.getOrPut(script) {
                when (script) {
                    "ja" -> TextRecognition.getClient(JapaneseTextRecognizerOptions.Builder().build())
                    "zh" -> TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
                    "ko" -> TextRecognition.getClient(KoreanTextRecognizerOptions.Builder().build())
                    "hi" -> TextRecognition.getClient(DevanagariTextRecognizerOptions.Builder().build())
                    else -> TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
                }
            }
            }
            recognizer.process(InputImage.fromBitmap(image, 0))
                .addOnSuccessListener { text ->
                    if (!closed) result.success(mapOf(
                        "width" to image.width, "height" to image.height, "text" to text.text,
                        "blocks" to text.textBlocks.map { block ->
                            val box = block.boundingBox
                            mapOf("text" to block.text, "x" to (box?.left ?: 0), "y" to (box?.top ?: 0),
                                "width" to (box?.width() ?: 0), "height" to (box?.height() ?: 0),
                                "lines" to block.lines.map { it.text })
                        }
                    ))
                }
                .addOnFailureListener { error -> if (!closed) result.error("recognition_failed", error.message, null) }
                .addOnCompleteListener { image.recycle(); busy = false }
        } catch (error: Exception) {
            bitmap?.recycle()
            activity.runOnUiThread {
                busy = false
                if (!closed) result.error("recognition_failed", error.message, null)
            }
        }
    }

    fun close() {
        closed = true
        channel.setMethodCallHandler(null)
        executor.shutdownNow()
        synchronized(clients) {
            clients.values.forEach { it.close() }
            clients.clear()
        }
    }
}
