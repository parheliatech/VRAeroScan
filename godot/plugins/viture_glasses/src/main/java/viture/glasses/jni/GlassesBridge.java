package viture.glasses.jni;

/**
 * JNI entry points into Viture's libglasses-jni.so.
 *
 * JNI binds native methods by fully-qualified class and method name, so this class MUST
 * keep Viture's exact package and name — it is an interface declaration for talking to
 * their library, written from the symbol table, not a copy of their code. Only the
 * methods VRAeroScan uses are declared; JNI resolves each one lazily on first call.
 *
 * Callback parameters are typed Object: the native side looks up the callback method by
 * name and signature on whatever object it is given, e.g. onImuPoseData([FJ)V and
 * onStateChange(II)V, so it does not care about the Java interface.
 *
 * Call sequence, as SpaceWalker 1.7.2.0 performs it:
 *   nativeXRDeviceInitialize(usbFd, null, productId)
 *   nativeRegisterViturePoseCallback(cb) / nativeRegisterStateCallback(cb)
 *   nativeXRDeviceStart()
 *   ...short delay...
 *   nativeOpenImu(MODE_POSE = 1, frequency = 3)
 */
public final class GlassesBridge {
    static {
        System.loadLibrary("glasses-jni");
    }

    private GlassesBridge() {}

    public static native boolean nativeXRDeviceInitialize(int usbFd, String unused, int productId);

    public static native void nativeXRDeviceStart();

    public static native void nativeXRDeviceStop();

    public static native void nativeXRDeviceRelease();

    /** 0 = GEN1, 1 = GEN2, 2 = Carina (6DoF). Pose callbacks only work for 0 and 1. */
    public static native int nativeGetDeviceType();

    public static native void nativeRegisterViturePoseCallback(Object callback);

    public static native void nativeUnregisterViturePoseCallback();

    public static native void nativeRegisterStateCallback(Object callback);

    public static native void nativeUnregisterStateCallback();

    /** mode: 0 = MODE_RAW, 1 = MODE_POSE. Returns 0 on success. */
    public static native int nativeOpenImu(int mode, int frequency);

    public static native int nativeCloseImu(int mode);

    public static native int nativeGetDisplayMode();

    public static native int nativeSetDisplayMode(int mode);

    public static native String nativeGetGlassesVersion();
}
