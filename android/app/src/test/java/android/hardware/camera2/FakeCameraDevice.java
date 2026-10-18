package android.hardware.camera2;

import android.hardware.camera2.params.InputConfiguration;
import android.hardware.camera2.params.OutputConfiguration;
import android.os.Handler;
import android.view.Surface;
import java.util.List;

/** Package-local framework fake so StateCallback error paths can close a real subtype. */
public final class FakeCameraDevice extends CameraDevice {
    private boolean closed;
    private final RuntimeException createSessionFailure;
    private final boolean configureSuccessfully;
    private final RuntimeException createRequestFailure;
    private FakeCameraCaptureSession lastSession;
    private CaptureRequest.Builder requestBuilder;
    private CameraCaptureSession.StateCallback sessionCallback;
    private boolean deferConfiguration;

    public FakeCameraDevice() { this(null, false, null); }
    public FakeCameraDevice(RuntimeException failure) { this(failure, false, null); }
    public FakeCameraDevice(boolean configureSuccessfully, RuntimeException requestFailure) {
        this(null, configureSuccessfully, requestFailure);
    }
    private FakeCameraDevice(RuntimeException sessionFailure, boolean configureSuccessfully,
                             RuntimeException requestFailure) {
        this.createSessionFailure = sessionFailure;
        this.configureSuccessfully = configureSuccessfully;
        this.createRequestFailure = requestFailure;
    }

    @Override public String getId() { return "fake"; }
    @Override public void createCaptureSession(List<Surface> outputs, CameraCaptureSession.StateCallback callback, Handler handler) {
        if (createSessionFailure != null) throw createSessionFailure;
        lastSession = new FakeCameraCaptureSession(this);
        sessionCallback = callback;
        if (deferConfiguration) return;
        if (configureSuccessfully) callback.onConfigured(lastSession);
        else callback.onConfigureFailed(lastSession);
    }
    @Override public void createCaptureSessionByOutputConfigurations(List<OutputConfiguration> outputs, CameraCaptureSession.StateCallback callback, Handler handler) { }
    @Override public void createReprocessableCaptureSession(InputConfiguration input, List<Surface> outputs, CameraCaptureSession.StateCallback callback, Handler handler) { }
    @Override public void createReprocessableCaptureSessionByConfigurations(InputConfiguration input, List<OutputConfiguration> outputs, CameraCaptureSession.StateCallback callback, Handler handler) { }
    @Override public void createConstrainedHighSpeedCaptureSession(List<Surface> outputs, CameraCaptureSession.StateCallback callback, Handler handler) { }
    @Override public CaptureRequest.Builder createCaptureRequest(int templateType) {
        if (createRequestFailure != null) throw createRequestFailure;
        return requestBuilder;
    }
    public void setDeferConfiguration(boolean defer) { deferConfiguration = defer; }
    public CameraCaptureSession.StateCallback getSessionCallback() { return sessionCallback; }
    public void setRequestBuilder(CaptureRequest.Builder builder) { requestBuilder = builder; }
    @Override public CaptureRequest.Builder createReprocessCaptureRequest(TotalCaptureResult result) { return null; }
    @Override public void close() { closed = true; }
    public boolean isClosed() { return closed; }
    public FakeCameraCaptureSession getLastSession() { return lastSession; }
}
