package com.androidwebcam.app.update

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.androidwebcam.app.BuildConfig
import java.util.concurrent.Executors

object AndroidUpdates {
    private var instance: UpdateCoordinator? = null
    var confirmation: Intent? = null

    @Synchronized fun get(context: Context): UpdateCoordinator {
        instance?.let { return it }
        val app = context.applicationContext
        val repository = ReleaseRepository()
        val installer = AndroidUpdateInstaller(app)
        val backend = ReleaseUpdateBackend(app.cacheDir, repository, installer,
            BuildConfig.VERSION_CODE.toLong(), Build.VERSION.SDK_INT)
        val main = Handler(Looper.getMainLooper())
        return UpdateCoordinator(backend, Executors.newSingleThreadExecutor()) { callback -> main.post(callback) }
            .also { instance = it }
    }
}

class UpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val coordinator = AndroidUpdates.get(context)
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirmation = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                AndroidUpdates.confirmation = confirmation
                coordinator.installationResult(if (confirmation != null) "Approve the update in Android's installer."
                    else "Android did not provide installation approval.", finished = confirmation == null)
            }
            PackageInstaller.STATUS_SUCCESS -> coordinator.installationResult("Update installed. Reopen WAMC.")
            PackageInstaller.STATUS_FAILURE_ABORTED -> coordinator.installationResult("Update installation cancelled.")
            else -> coordinator.installationResult("Android could not install the update. Check storage and installation permissions, then retry.")
        }
    }
}
