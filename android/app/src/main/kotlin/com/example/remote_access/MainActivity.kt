package com.example.remote_access

import android.content.ComponentName
import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "remote_access/input"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                val service = RemoteInputService.instance
                when (call.method) {
                    "isEnabled" -> result.success(isAccessibilityEnabled())
                    "openSettings" -> {
                        startActivity(
                            Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                        result.success(null)
                    }
                    "tap" -> {
                        service?.tap(call.argument<Double>("x")!!, call.argument<Double>("y")!!)
                        result.success(service != null)
                    }
                    "longpress" -> {
                        service?.longPress(
                            call.argument<Double>("x")!!,
                            call.argument<Double>("y")!!,
                            call.argument<Number>("ms")?.toLong() ?: 500L,
                        )
                        result.success(service != null)
                    }
                    "swipe" -> {
                        service?.swipe(
                            call.argument<Double>("x1")!!,
                            call.argument<Double>("y1")!!,
                            call.argument<Double>("x2")!!,
                            call.argument<Double>("y2")!!,
                            call.argument<Number>("ms")?.toLong() ?: 200L,
                        )
                        result.success(service != null)
                    }
                    "key" -> {
                        service?.globalAction(call.argument<String>("k") ?: "")
                        result.success(service != null)
                    }
                    "text" -> {
                        service?.typeText(call.argument<String>("v") ?: "")
                        result.success(service != null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "remote_access/capture")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        // Report the REAL foreground-service outcome. On Android
                        // 14+ startForeground(mediaProjection) throws without the
                        // project_media app-op; the service catches that and
                        // reports it here so Flutter can abort the session
                        // cleanly instead of crashing or hanging.
                        var replied = false
                        fun reply(ok: Boolean, err: String?) {
                            if (replied) return
                            replied = true
                            runOnUiThread {
                                if (ok) {
                                    result.success(true)
                                } else {
                                    result.error(
                                        "capture_failed",
                                        err ?: "Could not start screen capture.",
                                        null,
                                    )
                                }
                            }
                        }
                        ScreenCaptureService.startResultCallback = { ok, err -> reply(ok, err) }
                        try {
                            startForegroundService(Intent(this, ScreenCaptureService::class.java))
                        } catch (t: Throwable) {
                            ScreenCaptureService.startResultCallback = null
                            reply(false, t.message ?: t.javaClass.simpleName)
                        }
                    }
                    "stop" -> {
                        try {
                            stopService(Intent(this, ScreenCaptureService::class.java))
                        } catch (_: Throwable) {
                            // Service already gone.
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** True if our AccessibilityService is currently enabled by the user/MDM. */
    private fun isAccessibilityEnabled(): Boolean {
        val expected = ComponentName(this, RemoteInputService::class.java)
        val enabledServices = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return false

        return enabledServices.split(':').any {
            ComponentName.unflattenFromString(it) == expected
        }
    }
}
