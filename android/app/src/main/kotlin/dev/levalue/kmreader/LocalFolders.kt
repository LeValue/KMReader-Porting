package dev.levalue.kmreader

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

internal class LocalFolders(private val activity: MainActivity, messenger: BinaryMessenger) {
    companion object {
        private const val REQUEST_FOLDER = 7201
        private const val READ = Intent.FLAG_GRANT_READ_URI_PERMISSION
    }

    private val channel = MethodChannel(messenger, "dev.levalue.kmreader/local_folders")
    private val executor = Executors.newSingleThreadExecutor()
    private val resolver = activity.contentResolver
    private var selection: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "select" -> select(result)
                "list" -> run(result) { list(tree(call.arguments as String)) }
                "stage" -> run(result) { stage(tree(call.argument<String>("folder")!!), call.argument<String>("entry")!!) }
                "forget" -> run(result) {
                    val uri = Uri.parse(call.arguments as String)
                    if (resolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission }) {
                        resolver.releasePersistableUriPermission(uri, READ)
                    }
                    null
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun select(result: MethodChannel.Result) {
        if (selection != null) {
            result.error("picker_busy", null, null)
            return
        }
        selection = result
        try {
            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(READ or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            }, REQUEST_FOLDER)
        } catch (_: Exception) {
            selection = null
            result.error("folder_picker", "Could not open the folder picker.", null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_FOLDER) return
        val pending = selection ?: return
        selection = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending.success(null)
            return
        }
        run(pending) {
            resolver.takePersistableUriPermission(uri, READ)
            val id = DocumentsContract.getTreeDocumentId(uri)
            val doc = DocumentsContract.buildDocumentUriUsingTree(uri, id)
            val name = resolver.query(doc, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            }
            mapOf("id" to uri.toString(), "name" to (name ?: id.substringAfterLast('/').substringAfterLast(':')))
        }
    }

    private fun tree(raw: String): Uri {
        val uri = Uri.parse(raw)
        if (!DocumentsContract.isTreeUri(uri) ||
            resolver.persistedUriPermissions.none { it.uri == uri && it.isReadPermission }) {
            throw SecurityException("Folder access expired.")
        }
        return uri
    }

    private fun list(tree: Uri): List<Map<String, String>> {
        val fields = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE, Document.COLUMN_LAST_MODIFIED, Document.COLUMN_SIZE, Document.COLUMN_FLAGS)
        val directories = ArrayDeque<String>()
        val visited = mutableSetOf<String>()
        val found = mutableListOf<Map<String, String>>()
        directories.add(DocumentsContract.getTreeDocumentId(tree))
        while (directories.isNotEmpty()) {
            val parent = directories.removeFirst()
            if (!visited.add(parent)) continue
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parent)
            val cursor = resolver.query(children, fields, null, null, null) ?: throw IOException("Folder unavailable")
            cursor.use {
                if (it.extras.getBoolean(DocumentsContract.EXTRA_LOADING)) throw IOException("Folder is still loading")
                while (it.moveToNext()) {
                    val id = it.getString(0)
                    val name = it.getString(1) ?: continue
                    if (it.getString(2) == Document.MIME_TYPE_DIR) {
                        directories.add(id)
                    } else if ((it.getInt(5) and Document.FLAG_VIRTUAL_DOCUMENT) == 0) {
                        found.add(mapOf("id" to id, "name" to name, "stamp" to "${it.getLong(3)}:${it.getLong(4)}"))
                    }
                }
            }
        }
        return found
    }

    private fun stage(tree: Uri, id: String): String {
        val doc = DocumentsContract.buildDocumentUriUsingTree(tree, id)
        val staged = File.createTempFile("folder-import-", ".part", activity.cacheDir)
        try {
            val source = resolver.openInputStream(doc) ?: throw IOException("File unavailable")
            source.use { input -> staged.outputStream().use { output -> input.copyTo(output) } }
            return staged.path
        } catch (failure: Exception) {
            staged.delete()
            throw failure
        }
    }

    private fun run(result: MethodChannel.Result, action: () -> Any?) {
        executor.execute {
            try {
                val value = action()
                activity.runOnUiThread { result.success(value) }
            } catch (_: Exception) {
                activity.runOnUiThread { result.error("folder_access", "Could not read this folder.", null) }
            }
        }
    }

    fun close() {
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }
}
