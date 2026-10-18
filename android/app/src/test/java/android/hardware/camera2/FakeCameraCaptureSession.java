package android.hardware.camera2;

import android.hardware.camera2.params.OutputConfiguration;
import android.view.Surface;
import java.util.List;

public final class FakeCameraCaptureSession extends CameraCaptureSession {
    private final CameraDevice device;
    private boolean closed;
    private CaptureRequest request;
    private CaptureCallback callback;
    private boolean repeatingStopped;

    public FakeCameraCaptureSession(CameraDevice device) { this.device = device; }
    @Override public CameraDevice getDevice() { return device; }
    @Override public void prepare(Surface surface) { }
    @Override public void finalizeOutputConfigurations(List<OutputConfiguration> outputs) { }
    @Override public int capture(CaptureRequest request, CaptureCallback callback, android.os.Handler handler) { return 0; }
    @Override public int captureBurst(List<CaptureRequest> requests, CaptureCallback callback, android.os.Handler handler) { return 0; }
    @Override public int setRepeatingRequest(CaptureRequest request, CaptureCallback callback, android.os.Handler handler) { this.request = request; this.callback = callback; return 0; }
    public CaptureRequest getRequest() { return request; }
    public CaptureCallback getCallback() { return callback; }
    public boolean isRepeatingStopped() { return repeatingStopped; }
    @Override public int setRepeatingBurst(List<CaptureRequest> requests, CaptureCallback callback, android.os.Handler handler) { return 0; }
    @Override public void stopRepeating() { repeatingStopped = true; }
    @Override public void abortCaptures() { }
    @Override public boolean isReprocessable() { return false; }
    @Override public Surface getInputSurface() { return null; }
    @Override public void close() { closed = true; }
    public boolean isClosed() { return closed; }
}
