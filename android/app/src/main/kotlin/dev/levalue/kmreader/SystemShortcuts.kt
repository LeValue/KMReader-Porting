package dev.levalue.kmreader

import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

internal class SystemShortcuts(private val activity: MainActivity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "dev.levalue.kmreader/shortcuts")
    private var pending: String? = null
    private val action = "${activity.packageName}.LIBRARY_SHORTCUT"
    private val destinations = mapOf(
        "search" to (R.string.quick_search to R.drawable.shortcut_search),
        "downloads" to (R.string.quick_downloads to R.drawable.shortcut_downloads),
        "reading" to (R.string.quick_reading to R.drawable.shortcut_reading),
    )

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "takeAction" -> {
                    val destination = pending
                    pending = null
                    result.success(destination)
                }
                "openReaderWindow" -> {
                    val argument = call.arguments as? String
                    if (argument.isNullOrEmpty()) {
                        result.error("reader_target", null, null)
                    } else {
                        activity.startActivity(ReaderActivity.open(activity, "--reader-window", argument))
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        receive(activity.intent)
        publish()
    }

    fun publish() {
        if (activity is ReaderActivity || Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return
        val manager = activity.getSystemService(ShortcutManager::class.java) ?: return
        val launcher = activity.packageManager.getLaunchIntentForPackage(activity.packageName)
            ?.component ?: return
        try {
            if (manager.isRateLimitingActive) return
            val shortcuts = destinations.entries.take(manager.maxShortcutCountPerActivity)
                .map { (id, values) ->
                    ShortcutInfo.Builder(activity, id)
                        .setActivity(launcher)
                        .setShortLabel(activity.getString(values.first))
                        .setIcon(Icon.createWithResource(activity, values.second))
                        .setIntent(Intent(activity, MainActivity::class.java).apply {
                            this.action = this@SystemShortcuts.action
                            putExtra("destination", id)
                            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        })
                        .build()
                }
            manager.setDynamicShortcuts(shortcuts)
        } catch (_: IllegalStateException) {
            // The launcher may be unavailable while the device is locked.
        } catch (_: IllegalArgumentException) {
            // The launcher component may change while shortcuts are published.
        }
    }

    fun receive(intent: Intent?) {
        if (intent == null || intent.action != action) return
        val destination = intent.getStringExtra("destination") ?: return
        if (destination !in destinations) return
        intent.removeExtra("destination")
        pending = destination
        channel.invokeMethod("actionAvailable", null)
    }

    fun close() {
        channel.setMethodCallHandler(null)
    }
}
