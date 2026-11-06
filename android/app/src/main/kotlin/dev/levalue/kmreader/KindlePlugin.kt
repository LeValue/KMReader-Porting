package dev.levalue.kmreader

import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/** Binds the converter only on demand; the reader never starts Python. */
class KindlePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val handler = Handler(Looper.getMainLooper())
    private val pending = linkedMapOf<Int, Pair<String, MethodChannel.Result>>()
    private val deadlines = linkedMapOf<Int, Runnable>()
    private var nextId = 1
    private var worker: Messenger? = null
    private var bound = false
    private var idle: Runnable? = null
    private val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
        val entry = pending.remove(message.arg1)
        deadlines.remove(message.arg1)?.let { handler.removeCallbacks(it) }
        if (entry != null) entry.second.success(message.data.getString("result"))
        if (pending.isEmpty()) scheduleRelease()
        true
    })
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            worker = Messenger(binder)
            for ((id, entry) in pending.toMap()) send(id, entry.first)
        }
        override fun onServiceDisconnected(name: ComponentName) {
            worker = null
            failPending()
            release()
        }
    }
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "dev.levalue.kmreader/kindle")
        channel.setMethodCallHandler(this)
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "cancel") {
            val directory = call.argument<String>("directory")
            for ((id, entry) in pending.toMap()) {
                if (entry.first != directory) continue
                pending.remove(id)
                deadlines.remove(id)?.let { handler.removeCallbacks(it) }
                entry.second.error("cancelled", "Conversion cancelled", null)
            }
            if (pending.isEmpty()) release()
            result.success(null)
            return
        }
        if (call.method != "prepare") { result.notImplemented(); return }
        val directory = call.argument<String>("directory")
        if (directory == null) { result.error("directory", "Conversion directory missing", null); return }
        val file = File(directory).canonicalFile
        val privateRoot = File(context.applicationInfo.dataDir).canonicalFile
        if (!file.path.startsWith(privateRoot.path + File.separator) || !File(file, "receipt.json").isFile) {
            result.error("directory", "Conversion directory is outside application storage", null)
            return
        }
        idle?.let { handler.removeCallbacks(it) }
        val id = nextId++
        pending[id] = file.path to result
        val deadline = Runnable { failPending(); release() }
        deadlines[id] = deadline
        handler.postDelayed(deadline, 12 * 60 * 1000L)
        if (worker != null) send(id, file.path)
        else if (!bound) {
            bound = context.bindService(Intent(context, KindleConversionService::class.java), connection, Context.BIND_AUTO_CREATE)
            if (!bound) failPending()
        }
    }
    private fun send(id: Int, directory: String) {
        try {
            worker?.send(Message.obtain(null, 1, id, 0).apply {
                data = Bundle().apply { putString("directory", directory) }
                replyTo = replies
            })
        } catch (_: Exception) { failPending(); release() }
    }
    private fun failPending() {
        for (deadline in deadlines.values) handler.removeCallbacks(deadline)
        deadlines.clear()
        for ((_, entry) in pending) entry.second.error("converter", "Kindle conversion worker unavailable", null)
        pending.clear()
    }
    private fun scheduleRelease() {
        idle?.let { handler.removeCallbacks(it) }
        idle = Runnable { if (pending.isEmpty()) release() }
        handler.postDelayed(idle!!, 10_000)
    }
    private fun release() {
        idle?.let { handler.removeCallbacks(it) }
        idle = null
        worker = null
        if (bound) { bound = false; try { context.unbindService(connection) } catch (_: Exception) {} }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        failPending()
        release()
    }
}

/** A private process lets Android reclaim all converter memory after use. */
class KindleConversionService : Service() {
    private val executor = Executors.newSingleThreadExecutor()
    private val incoming = Messenger(Handler(Looper.getMainLooper()) { message ->
        val id = message.arg1
        val directory = message.data.getString("directory")
        val reply = message.replyTo
        if (directory != null && reply != null) executor.execute {
            val result = try {
                if (!Python.isStarted()) Python.start(AndroidPlatform(this))
                Python.getInstance().getModule("kmreader_kfx").callAttr("prepare", directory).toString()
            } catch (_: Throwable) {
                // Python exceptions may contain passages or filenames. They
                // never enter logcat, Flutter diagnostics or a public report.
                "{\"ok\":false,\"error\":{\"code\":\"conversion_unsupported\"}}"
            }
            try { reply.send(Message.obtain(null, 2, id, 0).apply {
                data = Bundle().apply { putString("result", result) }
            }) } catch (_: Exception) {}
        }
        true
    })
    override fun onBind(intent: Intent): IBinder = incoming.binder
    override fun onUnbind(intent: Intent): Boolean { stopSelf(); return false }
    override fun onDestroy() {
        executor.shutdownNow()
        super.onDestroy()
        android.os.Process.killProcess(android.os.Process.myPid())
    }
}
