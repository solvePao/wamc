package com.androidwebcam.app.update

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.net.Uri
import android.provider.Settings

/** Activity-owned dialogs observe process state only while the screen is visible. */
class UpdatePresenter(private val activity: Activity, private val coordinator: UpdateCoordinator) {
    private var dialog: AlertDialog? = null
    private var shown: UpdateState? = null
    private var streaming = true
    private var waitingForPermission = false

    fun resume() {
        coordinator.listener = ::render
        coordinator.check()
    }

    fun pause() {
        coordinator.listener = null
        dialog?.dismiss()
        dialog = null
        shown = null
    }

    fun streamingChanged(active: Boolean) {
        if (streaming == active) return
        streaming = active
        if (coordinator.state is UpdateState.Ready && coordinator.listener != null) {
            shown = null
            render(coordinator.state)
        }
    }

    private fun render(state: UpdateState) {
        AndroidUpdates.confirmation?.let { intent ->
            AndroidUpdates.confirmation = null
            try { activity.startActivity(intent) }
            catch (_: Exception) { coordinator.installationResult("Android's installer could not open. Retry the update.") }
            return
        }
        if (state == shown && !waitingForPermission) return
        shown = state
        if (state is UpdateState.Downloading && dialog?.isShowing == true && dialog?.getButton(AlertDialog.BUTTON_NEGATIVE)?.text == "Cancel") {
            dialog?.setMessage("Downloading update: ${state.percent}%")
            return
        }
        dialog?.dismiss()
        dialog = null
        val builder = AlertDialog.Builder(activity)
        when (state) {
            is UpdateState.Available -> builder.setTitle("WAMC ${state.release.version} available")
                .setMessage("Installed: ${com.androidwebcam.app.BuildConfig.VERSION_NAME}. Download and install the new version?")
                .setPositiveButton("Update") { _, _ -> coordinator.download() }
                .setNegativeButton("Later") { _, _ -> coordinator.dismiss() }
            is UpdateState.Downloading -> builder.setTitle("WAMC update")
                .setMessage("Downloading update: ${state.percent}%")
                .setNegativeButton("Cancel") { _, _ -> coordinator.dismiss() }
            is UpdateState.Ready -> {
                if (streaming) builder.setTitle("Update ready")
                    .setMessage("Stop streaming to install the update.")
                    .setNegativeButton("Close") { _, _ -> }
                    .setNeutralButton("Discard update") { _, _ -> coordinator.dismiss() }
                else if (!activity.packageManager.canRequestPackageInstalls()) {
                    waitingForPermission = false
                    builder.setTitle("Allow WAMC updates")
                        .setMessage("Allow WAMC to install updates in Android settings, then return here.")
                        .setPositiveButton("Open settings") { _, _ ->
                            waitingForPermission = true
                            try { activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:${activity.packageName}"))) }
                            catch (_: Exception) { coordinator.installationResult("Installation settings could not open.") }
                        }.setNegativeButton("Later") { _, _ -> coordinator.dismiss() }
                } else {
                    waitingForPermission = false
                    coordinator.install()
                    return
                }
            }
            is UpdateState.Message -> builder.setTitle("WAMC update").setMessage(state.text)
                .setPositiveButton("OK") { _, _ -> coordinator.dismiss() }
            else -> return
        }
        dialog = builder.setCancelable(false).create().also { it.show() }
    }
}
