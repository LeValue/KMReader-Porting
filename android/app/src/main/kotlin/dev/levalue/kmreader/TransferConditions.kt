package dev.levalue.kmreader

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Foreground events only; headless transfers use WorkManager constraints. */
class TransferConditions(private val context: Context, messenger: BinaryMessenger) {
    private val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val channel = MethodChannel(messenger, "dev.levalue.kmreader/background")
    private val handler = Handler(Looper.getMainLooper())
    private var closed = false
    private val network = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = report()
        override fun onLost(network: Network) = report()
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = report()
    }
    private val power = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) = report()
    }
    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "conditions") result.success(value()) else result.notImplemented()
        }
        connectivity.registerDefaultNetworkCallback(network)
        context.registerReceiver(power, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
    }
    private fun value(): Map<String, Boolean> {
        val active = connectivity.activeNetwork
        val capabilities = connectivity.getNetworkCapabilities(active)
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        return mapOf(
            "connected" to (capabilities != null),
            "metered" to connectivity.isActiveNetworkMetered,
            "charging" to (status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL)
        )
    }
    private fun report() {
        handler.post { if (!closed) channel.invokeMethod("conditions", value()) }
    }
    fun close() {
        closed = true
        channel.setMethodCallHandler(null)
        connectivity.unregisterNetworkCallback(network)
        context.unregisterReceiver(power)
    }
}
