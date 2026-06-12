package com.example.remote_access

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Context
import android.content.Intent
import android.graphics.Path
import android.os.Bundle
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import kotlin.math.max

/**
 * Executes remote-control commands forwarded from Dart (via the
 * `remote_access/input` MethodChannel in MainActivity). Coordinates arrive
 * normalized 0..1 of the captured screen and are scaled to real pixels here.
 *
 * Requires the user (or MDM) to enable this service in Accessibility settings.
 */
class RemoteInputService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: RemoteInputService? = null
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) { /* not used */ }

    override fun onInterrupt() { /* not used */ }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    private fun screenSize(): Pair<Int, Int> {
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val bounds = wm.currentWindowMetrics.bounds // API 30+
        return Pair(bounds.width(), bounds.height())
    }

    fun tap(xPct: Double, yPct: Double) {
        val (w, h) = screenSize()
        val path = Path().apply { moveTo((xPct * w).toFloat(), (yPct * h).toFloat()) }
        dispatchStroke(path, 60)
    }

    fun longPress(xPct: Double, yPct: Double, ms: Long) {
        val (w, h) = screenSize()
        val path = Path().apply { moveTo((xPct * w).toFloat(), (yPct * h).toFloat()) }
        dispatchStroke(path, max(ms, 400))
    }

    fun swipe(x1: Double, y1: Double, x2: Double, y2: Double, ms: Long) {
        val (w, h) = screenSize()
        val path = Path().apply {
            moveTo((x1 * w).toFloat(), (y1 * h).toFloat())
            lineTo((x2 * w).toFloat(), (y2 * h).toFloat())
        }
        dispatchStroke(path, max(ms, 50))
    }

    private fun dispatchStroke(path: Path, duration: Long) {
        val stroke = GestureDescription.StrokeDescription(path, 0, duration)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        dispatchGesture(gesture, null, null)
    }

    fun globalAction(key: String) {
        val action = when (key) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents" -> GLOBAL_ACTION_RECENTS
            else -> return
        }
        performGlobalAction(action)
    }

    fun typeText(text: String) {
        val node = findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return
        try {
            if (!node.isEditable) return
            val existing = node.text?.toString() ?: ""
            val args = Bundle().apply {
                putCharSequence(
                    AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                    existing + text,
                )
            }
            node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        } finally {
            node.recycle()
        }
    }
}
