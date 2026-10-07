package com.ambi.gold_paper_trading

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Binder

// Offline bridge for Friday (user project: connect the apps,
// offline-first). Serves the latest REAL snapshot the Dart side wrote to
// SharedPreferences (quote, paper balance, open positions) to Friday on
// the same phone - no network, no account, nothing leaves the device.
// Only Friday may read it: any other caller gets nothing.
class OroBridgeProvider : ContentProvider() {

    companion object {
        private const val FRIDAY_PACKAGE = "com.friday.assistant"
    }

    override fun onCreate(): Boolean = true

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor? {
        val ctx = context ?: return null
        val caller = try {
            ctx.packageManager.getNameForUid(Binder.getCallingUid())
        } catch (e: Exception) {
            null
        } ?: return null
        if (caller != FRIDAY_PACKAGE) return null
        val prefs = ctx.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val json = prefs.getString("flutter.oro_bridge_snapshot", null) ?: return null
        val cursor = MatrixCursor(arrayOf("json"))
        cursor.addRow(arrayOf(json))
        return cursor
    }

    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
}
