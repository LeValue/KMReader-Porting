package dev.levalue.kmreader

import android.os.Build
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.view.ViewTreeObserver
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var ocr: ReaderOcr? = null
    private var readerActive = false
    private var previousCutout = 0
    private var previousVisibility = 0
    private var previousBars = 0
    private var previousBehavior = 0
    private var readerChannel: MethodChannel? = null
    private var lastInsets: Map<String, Int>? = null
    private val insetObserver = ViewTreeObserver.OnGlobalLayoutListener {
        if (readerActive) reportReaderInsets()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ocr = ReaderOcr(this, flutterEngine.dartExecutor.binaryMessenger)
        readerChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "dev.levalue.kmreader/reader_display")
        readerChannel!!.setMethodCallHandler { call, result ->
            if (call.method == "setReaderMode" && call.arguments is Boolean) {
                setReaderMode(call.arguments as Boolean)
                result.success(readerInsets())
            } else {
                result.notImplemented()
            }
        }
    }

    // Independent of visibility: hiding the status bar does not remove a notch.
    // Do not replace Flutter's own WindowInsets listener on its rendering view.
    @Suppress("DEPRECATION")
    private fun readerInsets(): Map<String, Int> {
        val insets = window.decorView.rootWindowInsets
        var left = 0
        var top = 0
        var right = 0
        var bottom = 0
        var cutoutLeft = 0
        var cutoutTop = 0
        var cutoutRight = 0
        var cutoutBottom = 0
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && insets != null) {
            val bars = insets.getInsetsIgnoringVisibility(WindowInsets.Type.systemBars())
            left = bars.left
            top = bars.top
            right = bars.right
            bottom = bars.bottom
        } else if (insets != null) {
            left = insets.stableInsetLeft
            top = insets.stableInsetTop
            right = insets.stableInsetRight
            bottom = insets.stableInsetBottom
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            insets?.displayCutout?.let { cutout ->
                cutoutLeft = cutout.safeInsetLeft
                cutoutTop = cutout.safeInsetTop
                cutoutRight = cutout.safeInsetRight
                cutoutBottom = cutout.safeInsetBottom
                left = maxOf(left, cutout.safeInsetLeft)
                top = maxOf(top, cutout.safeInsetTop)
                right = maxOf(right, cutout.safeInsetRight)
                bottom = maxOf(bottom, cutout.safeInsetBottom)
            }
        }
        return mapOf("left" to left, "top" to top, "right" to right, "bottom" to bottom,
            "cutoutLeft" to cutoutLeft, "cutoutTop" to cutoutTop,
            "cutoutRight" to cutoutRight, "cutoutBottom" to cutoutBottom)
    }

    private fun reportReaderInsets() {
        val insets = readerInsets()
        if (insets != lastInsets) {
            lastInsets = insets
            readerChannel?.invokeMethod("readerInsets", insets)
        }
    }

    @Suppress("DEPRECATION")
    private fun setReaderMode(enabled: Boolean) {
        if (enabled && !readerActive) {
            lastInsets = null
            window.decorView.viewTreeObserver.addOnGlobalLayoutListener(insetObserver)
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
        if (!enabled) {
            window.decorView.viewTreeObserver.removeOnGlobalLayoutListener(insetObserver)
        }
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
        if (enabled) {
            reportReaderInsets()
            window.decorView.post { if (readerActive) reportReaderInsets() }
        }
    }

    override fun onDestroy() {
        ocr?.close()
        ocr = null
        window.decorView.viewTreeObserver.removeOnGlobalLayoutListener(insetObserver)
        readerChannel?.setMethodCallHandler(null)
        readerChannel = null
        super.onDestroy()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && readerActive) setReaderMode(true)
    }
}
