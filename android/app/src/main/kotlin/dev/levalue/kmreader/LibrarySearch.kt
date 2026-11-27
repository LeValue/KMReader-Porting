package dev.levalue.kmreader

import android.app.Activity
import android.app.SearchManager
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Bundle
import android.provider.BaseColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

internal class LibraryIndex(context: Context, messenger: BinaryMessenger) {
    private val prefs = context.getSharedPreferences("library_search", Context.MODE_PRIVATE)
    private val channel = MethodChannel(messenger, "dev.levalue.kmreader/library_index")

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "publish") {
                val snapshot = call.arguments as? String
                if (snapshot == null) {
                    result.error("invalid_index", null, null)
                } else {
                    prefs.edit().putString("entries", snapshot).apply()
                    result.success(null)
                }
            } else result.notImplemented()
        }
    }

    fun close() { channel.setMethodCallHandler(null) }
}

private fun Context.indexEntries(): Sequence<JSONObject> {
    val raw = getSharedPreferences("library_search", Context.MODE_PRIVATE)
        .getString("entries", null) ?: return emptySequence()
    val entries = runCatching { JSONArray(raw) }.getOrNull() ?: return emptySequence()
    return (0 until entries.length()).asSequence().mapNotNull(entries::optJSONObject)
}

class LibrarySearchProvider : ContentProvider() {
    override fun onCreate() = true

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
                       selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val rows = MatrixCursor(arrayOf(BaseColumns._ID, SearchManager.SUGGEST_COLUMN_TEXT_1,
            SearchManager.SUGGEST_COLUMN_INTENT_DATA_ID))
        if (uri.pathSegments.firstOrNull() != SearchManager.SUGGEST_URI_PATH_QUERY) return rows
        val query = (selectionArgs?.firstOrNull() ?: uri.pathSegments.getOrNull(1)).orEmpty().trim()
        if (query.length < 2) return rows
        context?.indexEntries()?.filter { it.optString("title").contains(query, ignoreCase = true) }
            ?.take(20)?.forEachIndexed { index, item ->
                rows.addRow(arrayOf(index, item.getString("title"), item.getString("argument")))
            }
        return rows
    }

    override fun getType(uri: Uri) = SearchManager.SUGGEST_MIME_TYPE
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun update(uri: Uri, values: ContentValues?, selection: String?,
                        selectionArgs: Array<out String>?): Int = 0
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
}

class IndexedLibraryActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val argument = intent.data?.lastPathSegment
        if (intent.action == Intent.ACTION_VIEW && intent.data?.scheme == "kmreader" &&
            intent.data?.host == "indexed-book" && argument != null &&
            indexEntries().any { it.optString("argument") == argument }) {
            startActivity(ReaderActivity.open(this, "--indexed-book", argument))
        }
        finish()
    }
}
