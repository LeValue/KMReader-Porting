package dev.levalue.kmreader

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * A separate entry point lets the default icon be disabled without disabling
 * MainActivity, which is also the target of the alternate launcher aliases.
 * Flutter tools also require the default launcher to be an activity element.
 */
class LauncherDefault : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startActivity(Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        })
        finish()
    }
}
