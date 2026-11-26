# Shizuku loads this Binder by name and calls its public no-argument constructor.
-keep class com.reareyes.app.RearDisplayService {
    public <init>();
}

# Vosk uses JNA to resolve native entry points by name.
-keep class org.vosk.LibVosk { *; }
-keep class com.sun.jna.** { *; }
-dontwarn java.awt.**
