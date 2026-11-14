package dev.levalue.kmreader

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

class AppUpdater(private val activity: FlutterFragmentActivity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "dev.levalue.kmreader/updates")
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var closed = false
    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "supportedAbis") { result.success(Build.SUPPORTED_ABIS.toList()); return@setMethodCallHandler }
            if (call.method != "install" || call.arguments !is Map<*, *>) { result.notImplemented(); return@setMethodCallHandler }
            val path = call.argument<String>("path") ?: ""
            val expectedCode = call.argument<Number>("build")?.toLong()
            val expectedVersion = call.argument<String>("version")
            val expectedSource = call.argument<String>("source")
            executor.execute {
                try {
                    val file = File(path).canonicalFile
                    require(file.parentFile == File(activity.filesDir, "updates").canonicalFile && file.extension == "apk")
                    val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
                    val update = activity.packageManager.getPackageArchiveInfo(file.path, flags) ?: error("Invalid APK")
                    val installed = activity.packageManager.getPackageInfo(activity.packageName, flags)
                    require(update.packageName == activity.packageName)
                    val newCode = if (Build.VERSION.SDK_INT >= 28) update.longVersionCode else update.versionCode.toLong()
                    val oldCode = if (Build.VERSION.SDK_INT >= 28) installed.longVersionCode else installed.versionCode.toLong()
                    require(newCode > oldCode && newCode == expectedCode && update.versionName == expectedVersion)
                    java.util.zip.ZipFile(file).use { zip ->
                        val entry = zip.getEntry("assets/flutter_assets/assets/build/source.json") ?: error("Missing source")
                        require(entry.size in 0L..65536L)
                        val bytes = ByteArray(65537)
                        var count = 0
                        zip.getInputStream(entry).use { input ->
                            while (count < bytes.size) {
                                val read = input.read(bytes, count, bytes.size - count)
                                if (read < 0) break
                                count += read
                            }
                        }
                        require(count <= 65536)
                        val source = org.json.JSONObject(String(bytes, 0, count, Charsets.UTF_8))
                        require(source.getString("source") == expectedSource && source.getString("version") == expectedVersion && source.getLong("build") == expectedCode)
                    }
                    fun signers(info: android.content.pm.PackageInfo): List<String> {
                        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
                        return signatures?.map { signature -> MessageDigest.getInstance("SHA-256").digest(signature.toByteArray()).joinToString("") { "%02x".format(it.toInt() and 255) } }?.sorted() ?: emptyList()
                    }
                    require(signers(installed).size == 1 && signers(update) == signers(installed))
                    main.post {
                        if (!closed) {
                            try {
                                if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) {
                                    activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
                                    result.success(false)
                                } else {
                                    val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", file)
                                    activity.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri,"application/vnd.android.package-archive").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                                    result.success(true)
                                }
                            } catch (_: Exception) { result.error("update_install", "Impossibile avviare l'installazione", null) }
                        }
                    }
                } catch (_: Exception) {
                    main.post { if (!closed) result.error("update_invalid", "Il pacchetto non corrisponde a questa app o alla sua firma", null) }
                }
            }
        }
    }
    fun close() { closed = true; channel.setMethodCallHandler(null); executor.shutdownNow() }
}
