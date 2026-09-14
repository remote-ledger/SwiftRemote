package org.nslabs.ir_blaster

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File

/**
 * Hands a downloaded APK to the system package installer.
 *
 * A normal app cannot replace itself silently; the most it can do is point
 * the installer at a file and let the user confirm. Since Android 8 that
 * also needs REQUEST_INSTALL_PACKAGES *and* a per-app grant the user makes
 * in Settings, so callers should check [canRequestInstall] first and send
 * the user to [openInstallSettings] when it returns false.
 */
object ApkInstaller {

    /** Whether the user has allowed this app to install packages. */
    fun canRequestInstall(activity: Activity): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.packageManager.canRequestPackageInstalls()
        } else {
            // Before Oreo the grant was a single global setting, not per app.
            true
        }
    }

    /** Opens the settings page where that grant is made. */
    fun openInstallSettings(activity: Activity) {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:" + activity.packageName)
            )
        } else {
            Intent(Settings.ACTION_SECURITY_SETTINGS)
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        activity.startActivity(intent)
    }

    /**
     * Launches the installer for [path].
     *
     * The file lives in our own cache, which the installer cannot read
     * directly, so it is handed over as a FileProvider content:// URI with
     * a read grant attached to the intent.
     */
    fun install(activity: Activity, path: String) {
        val file = File(path)
        if (!file.exists()) {
            throw IllegalArgumentException("APK not found: $path")
        }
        val uri: Uri = FileProvider.getUriForFile(
            activity,
            activity.packageName + ".fileprovider",
            file
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        activity.startActivity(intent)
    }
}
