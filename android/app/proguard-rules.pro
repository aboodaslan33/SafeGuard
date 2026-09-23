# SafeGuard release rules (R8). Flutter and the plugins ship their own
# consumer rules; only project-specific additions live here.

# Flutter's embedding references Play Core (deferred components) optionally;
# SafeGuard doesn't use it.
-dontwarn com.google.android.play.core.**

# Release builds carry no verbose/debug/info logging. Warnings and errors
# stay (constant messages + exception class names only; see Phase6Test).
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
    public static int i(...);
}

# Services, receivers and activities are kept through the manifest. The
# engine has no reflection, serialization or JNI entry points to keep.
