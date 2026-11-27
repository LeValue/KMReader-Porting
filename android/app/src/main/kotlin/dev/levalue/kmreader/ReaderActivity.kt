package dev.levalue.kmreader

import android.content.Context
import android.content.Intent

class ReaderActivity : MainActivity() {
    companion object {
        fun open(context: Context, mode: String, argument: String): Intent =
            Intent(context, ReaderActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_DOCUMENT or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
                .putStringArrayListExtra("dart_entrypoint_args", arrayListOf(mode, argument))
    }
}
