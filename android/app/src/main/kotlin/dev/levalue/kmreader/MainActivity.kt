package dev.levalue.kmreader

import android.os.Build
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var readerActive = false
    private var previousCutout = 0
    private var previousVisibility = 0
    private var previousBars = 0
    private var previousBehavior = 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "dev.levalue.kmreader/reader_display").setMethodCallHandler { call, result ->
            if (call.method == "setReaderMode" && call.arguments is Boolean) {
                setReaderMode(call.arguments as Boolean)
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun setReaderMode(enabled: Boolean) {
        if (enabled && !readerActive) {
            previousVisibility = window.decorView.systemUiVisibility
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                previousCutout = window.attributes.layoutInDisplayCutoutMode
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val insets = window.decorView.rootWindowInsets
                previousBars = 0
                if (insets == null || insets.isVisible(WindowInsets.Type.statusBars())) {
                    previousBars = previousBars or WindowInsets.Type.statusBars()
                }
                if (insets == null || insets.isVisible(WindowInsets.Type.navigationBars())) {
                    previousBars = previousBars or WindowInsets.Type.navigationBars()
                }
                previousBehavior = window.insetsController?.systemBarsBehavior ?: 0
            }
        }
        if (!enabled && !readerActive) return
        readerActive = enabled
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val attributes = window.attributes
            val cutout = if (!enabled) previousCutout
                else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                else WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            if (attributes.layoutInDisplayCutoutMode != cutout) {
                attributes.layoutInDisplayCutoutMode = cutout
                window.attributes = attributes
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.apply {
                if (enabled) {
                    systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                    hide(WindowInsets.Type.systemBars())
                } else {
                    systemBarsBehavior = previousBehavior
                    hide(WindowInsets.Type.systemBars())
                    if (previousBars != 0) show(previousBars)
                }
            }
        } else {
            window.decorView.systemUiVisibility = if (enabled)
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                else previousVisibility
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && readerActive) setReaderMode(true)
    }
}
