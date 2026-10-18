package com.androidwebcam.app.update

import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean

interface UpdateBackend {
    fun latest(): AndroidRelease?
    fun download(release: AndroidRelease, cancelled: AtomicBoolean, progress: (Int) -> Unit): File
    fun install(file: File, release: AndroidRelease)
}

sealed class UpdateState {
    object Idle : UpdateState()
    object Checking : UpdateState()
    data class Available(val release: AndroidRelease) : UpdateState()
    data class Downloading(val percent: Int) : UpdateState()
    data class Ready(val file: File, val release: AndroidRelease) : UpdateState()
    data class Message(val text: String) : UpdateState()
}

/** Process-owned state; listeners attach only while their activity is resumed. */
class UpdateCoordinator(private val backend: UpdateBackend, private val worker: Executor,
    private val dispatch: (() -> Unit) -> Unit) {
    var state: UpdateState = UpdateState.Idle
        private set
    var listener: ((UpdateState) -> Unit)? = null
        set(value) { field = value; value?.invoke(state) }
    var installationInProgress = false
        private set
    private var checked = false
    private var generation = 0
    private var cancellation = AtomicBoolean(false)

    fun check(manual: Boolean = false) {
        if (installationInProgress || state is UpdateState.Checking || state is UpdateState.Downloading || state is UpdateState.Ready) return
        if (checked && !manual) return
        checked = true
        val operation = ++generation
        publish(UpdateState.Checking)
        worker.execute {
            try {
                val release = backend.latest()
                dispatch {
                    if (generation == operation) publish(release?.let { UpdateState.Available(it) }
                        ?: if (manual) UpdateState.Message("WAMC is up to date.") else UpdateState.Idle)
                }
            } catch (error: Exception) {
                dispatch { if (generation == operation) publish(if (manual)
                    UpdateState.Message(error.message ?: "Update check failed") else UpdateState.Idle) }
            }
        }
    }

    fun download() {
        val release = (state as? UpdateState.Available)?.release ?: return
        val operation = ++generation
        val cancelled = AtomicBoolean(false)
        cancellation = cancelled
        publish(UpdateState.Downloading(0))
        worker.execute {
            try {
                val file = backend.download(release, cancelled) { percent ->
                    dispatch { if (generation == operation) publish(UpdateState.Downloading(percent)) }
                }
                dispatch {
                    if (generation == operation) publish(UpdateState.Ready(file, release)) else file.delete()
                }
            } catch (error: Exception) {
                dispatch { if (generation == operation) publish(UpdateState.Message(error.message ?: "Update download failed")) }
            }
        }
    }

    fun install() {
        val ready = state as? UpdateState.Ready ?: return
        installationInProgress = true
        publish(UpdateState.Message("Waiting for Android installation approval…"))
        worker.execute {
            try { backend.install(ready.file, ready.release) }
            catch (error: Exception) { dispatch { installationResult(error.message ?: "Installation failed") } }
            finally { ready.file.delete() }
        }
    }

    fun dismiss() {
        cancellation.set(true)
        generation++
        (state as? UpdateState.Ready)?.file?.delete()
        publish(UpdateState.Idle)
    }

    fun installationResult(message: String, finished: Boolean = true) {
        installationInProgress = !finished
        publish(UpdateState.Message(message))
    }
    private fun publish(value: UpdateState) { state = value; listener?.invoke(value) }
}
