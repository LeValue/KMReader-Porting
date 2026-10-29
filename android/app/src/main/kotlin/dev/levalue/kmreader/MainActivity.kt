package dev.levalue.kmreader

import android.content.pm.ApplicationInfo
import android.content.ComponentName
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import java.io.ByteArrayOutputStream
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
    private var transferConditions: TransferConditions? = null
    private var ocr: ReaderOcr? = null
    private var exporter: FileExporter? = null
    private var privacyChannel: MethodChannel? = null
    private var readerStatusBarVisible = false
    private var readerActive = false
    private var ownsKeepAwake = false
    private var previousKeepAwake = false
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
        transferConditions = TransferConditions(this, flutterEngine.dartExecutor.binaryMessenger)
        ocr = ReaderOcr(this, flutterEngine.dartExecutor.binaryMessenger)
        exporter = FileExporter(this, flutterEngine.dartExecutor.binaryMessenger)
        privacyChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.levalue.kmreader/privacy")
        privacyChannel!!.setMethodCallHandler { call, result ->
            if (call.method == "getAppIcons") {
                val variants = mapOf("Default" to "default", "Classic" to "classic", "Legacy" to "legacy")
                result.success(variants.filter { (name, _) ->
                    val state = packageManager.getComponentEnabledSetting(ComponentName(this, "dev.levalue.kmreader.Launcher$name"))
                    state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED || (state == PackageManager.COMPONENT_ENABLED_STATE_DEFAULT && name == "Default")
                }.values.toList())
            } else if (call.method == "setAppIcon" && call.arguments is String) {
                val selected = mapOf("default" to "Default", "classic" to "Classic", "legacy" to "Legacy")[call.arguments as String]
                if (selected == null) { result.error("icon", "Unknown app icon", null); return@setMethodCallHandler }
                // Enable the new launcher first, retaining a launchable component.
                packageManager.setComponentEnabledSetting(ComponentName(this, "dev.levalue.kmreader.Launcher$selected"), PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP)
                for (name in listOf("Default", "Classic", "Legacy")) {
                    if (name != selected) packageManager.setComponentEnabledSetting(ComponentName(this, "dev.levalue.kmreader.Launcher$name"), PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP)
                }
                result.success(null)
            } else if (call.method == "setProtected" && call.arguments is Boolean) {
                if (call.arguments as Boolean) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                result.success(null)
            } else result.notImplemented()
        }
        readerChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "dev.levalue.kmreader/reader_display")
        readerChannel!!.setMethodCallHandler { call, result ->
            if (call.method == "getReaderStatusBarVisible") {
                result.success(if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) window.decorView.rootWindowInsets?.isVisible(WindowInsets.Type.statusBars()) ?: false
                    else (window.decorView.systemUiVisibility and View.SYSTEM_UI_FLAG_FULLSCREEN) == 0)
            } else if (call.method == "getKeepAwake") {
                result.success((window.attributes.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) != 0)
            } else if (call.method == "setKeepAwake" && call.arguments is Boolean) {
                val enabled = call.arguments as Boolean
                if (enabled && !ownsKeepAwake) {
                    previousKeepAwake = (window.attributes.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) != 0
                    ownsKeepAwake = true
                }
                if (enabled) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                else if (ownsKeepAwake) {
                    if (!previousKeepAwake) window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    ownsKeepAwake = false
                }
                result.success(null)
            } else if (call.method == "captureScreenshot" &&
                (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0 &&
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                // PixelCopy captures WebView hybrid composition without replacing
                // Flutter's rendering surface (which can stall test screenshots).
                val bitmap = Bitmap.createBitmap(window.decorView.width, window.decorView.height, Bitmap.Config.ARGB_8888)
                PixelCopy.request(window, bitmap, { status ->
                    try {
                        if (status != PixelCopy.SUCCESS) result.error("capture_failed", "PixelCopy failed: $status", null)
                        else ByteArrayOutputStream().use { output ->
                            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
                            result.success(output.toByteArray())
                        }
                    } finally { bitmap.recycle() }
                }, Handler(Looper.getMainLooper()))
            } else if (call.method == "setReaderStatusBarVisible" && call.arguments is Boolean) {
                readerStatusBarVisible = call.arguments as Boolean
                if (readerActive) setReaderMode(true)
                result.success(null)
            } else if (call.method == "setReaderMode" && call.arguments is Boolean) {
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
        if (enabled && readerStatusBarVisible) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                window.insetsController?.show(WindowInsets.Type.statusBars())
            } else {
                window.decorView.systemUiVisibility = window.decorView.systemUiVisibility and View.SYSTEM_UI_FLAG_FULLSCREEN.inv()
            }
        }
        if (enabled) {
            reportReaderInsets()
            window.decorView.post { if (readerActive) reportReaderInsets() }
        }
    }

    override fun onDestroy() {
        transferConditions?.close()
        transferConditions = null
        privacyChannel?.setMethodCallHandler(null)
        privacyChannel = null
        ocr?.close()
        ocr = null
        exporter?.close()
        exporter = null
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
