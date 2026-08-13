package com.akram.ecosystem.accessibility

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.ClipData
import android.content.ClipboardManager
import android.graphics.Path
import android.graphics.PixelFormat
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Injects touch gestures and navigation actions on behalf of the Mac.
 *
 * Gesture dispatch is only available to an AccessibilityService, so this wraps
 * the already-enabled clipboard service rather than adding a second permission.
 */
object RemoteInput {
    private const val TAG = "EcosysInput"
    private val handler = Handler(Looper.getMainLooper())

    @Volatile
    var service: AccessibilityService? = null

    val isAvailable: Boolean get() = service != null

    fun tap(x: Float, y: Float, longPress: Boolean) {
        resetTypingContext()
        val path = Path().apply { moveTo(x, y) }
        dispatch(path, if (longPress) 600L else 40L)
    }

    fun swipe(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Long) {
        resetTypingContext()
        val path = Path().apply {
            moveTo(x1, y1)
            lineTo(x2, y2)
        }
        dispatch(path, durationMs.coerceIn(30L, 3_000L))
    }

    // MARK: continuous scrolling
    //
    // A trackpad produces a stream of small deltas. Replaying each one as its own
    // swipe felt like a series of flicks, so the Mac drives one long gesture and
    // this keeps it alive with continued strokes — the phone sees a single finger
    // dragging, which is what its own fling physics expect.

    private const val SEGMENT_MS = 70L

    private var scrollStroke: GestureDescription.StrokeDescription? = null
    private var scrollX = 0f
    private var scrollY = 0f

    fun scroll(phase: String, x: Float, y: Float) {
        val service = service ?: return
        handler.post {
            when (phase) {
                "begin" -> {
                    val path = Path().apply { moveTo(x, y) }
                    val stroke = GestureDescription.StrokeDescription(
                        path, 0, SEGMENT_MS, true)
                    scrollStroke = stroke
                    scrollX = x
                    scrollY = y
                    send(service, stroke)
                }
                "move", "end" -> {
                    val previous = scrollStroke ?: return@post
                    val continuing = phase == "move"
                    // A zero-length path is rejected; nudge it a hair.
                    val toY = if (x == scrollX && y == scrollY) y + 0.5f else y
                    val path = Path().apply {
                        moveTo(scrollX, scrollY)
                        lineTo(x, toY)
                    }
                    val stroke = runCatching {
                        previous.continueStroke(path, 0, SEGMENT_MS, continuing)
                    }.getOrNull() ?: run {
                        scrollStroke = null
                        return@post
                    }
                    scrollStroke = if (continuing) stroke else null
                    scrollX = x
                    scrollY = toY
                    send(service, stroke)
                }
            }
        }
    }

    private fun send(
        service: AccessibilityService,
        stroke: GestureDescription.StrokeDescription,
    ) {
        runCatching {
            service.dispatchGesture(
                GestureDescription.Builder().addStroke(stroke).build(), null, null)
        }.onFailure { Log.w(TAG, "scroll dispatch failed: $it") }
    }

    fun globalAction(key: String): Boolean {
        val service = service ?: return false
        when (key) {
            "enter" -> {
                handler.post { imeEnter(service) }
                return true
            }
            "backspace" -> {
                handler.post { deleteLastCharacter(service) }
                return true
            }
        }
        resetTypingContext()
        val action = when (key) {
            "back" -> AccessibilityService.GLOBAL_ACTION_BACK
            "home" -> AccessibilityService.GLOBAL_ACTION_HOME
            "recents" -> AccessibilityService.GLOBAL_ACTION_RECENTS
            "notifications" -> AccessibilityService.GLOBAL_ACTION_NOTIFICATIONS
            "lock" -> AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN
            else -> return false
        }
        handler.post { service.performGlobalAction(action) }
        Log.i(TAG, "global action $key")
        return true
    }

    /**
     * Text we know is really in the focused field, or null when unknown.
     *
     * Reading the field is not trustworthy: an empty field often reports its
     * placeholder as its text, and plenty of apps expose no hint metadata at all
     * to tell the two apart. So the first keystroke goes in by paste — which
     * needs no knowledge of the content and lands at the caret — and the result
     * tells us what the field really holds. After that we track it ourselves.
     */
    @Volatile
    private var knownText: String? = null

    /** Anything that can move focus invalidates what we think the field holds. */
    /**
     * After a call is answered from the Mac, click the in-call screen's Speaker
     * button so the user can talk without picking the phone up. Best effort:
     * retries for a few seconds while the in-call UI appears, then gives up
     * silently (e.g. when the Mac pressed Decline and no call screen exists).
     */
    fun tapSpeakerSoon() {
        var attempts = 0
        lateinit var attempt: Runnable
        attempt = Runnable {
            val clicked = clickByLabel("Speaker")
            if (!clicked && ++attempts < 8) handler.postDelayed(attempt, 500)
        }
        handler.postDelayed(attempt, 800)
    }

    private fun clickByLabel(label: String): Boolean {
        val service = service ?: return false
        val roots = (runCatching { service.windows }.getOrNull().orEmpty()
            .mapNotNull { it.root } + listOfNotNull(service.rootInActiveWindow))
        for (root in roots) {
            val matches = root.findAccessibilityNodeInfosByText(label) ?: continue
            for (node in matches) {
                var candidate: android.view.accessibility.AccessibilityNodeInfo? = node
                while (candidate != null && !candidate.isClickable) {
                    candidate = candidate.parent
                }
                if (candidate?.performAction(
                        android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK)
                    == true) return true
            }
        }
        return false
    }

    fun resetTypingContext() {
        knownText = null
    }

    fun typeText(text: String) {
        val service = service ?: return
        handler.post {
            val node = service.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            if (node == null) {
                Log.w(TAG, "no focused text field")
                return@post
            }
            val known = knownText
            if (known.isNullOrEmpty()) {
                pasteAtCaret(service, node, text)
            } else {
                // Non-empty means no placeholder is showing, so the field's own
                // text is authoritative again (the user may have edited on the
                // phone between keystrokes).
                val current = node.text?.toString()?.takeIf { it.isNotEmpty() } ?: known
                setFocusedText(node, current + text)
            }
        }
    }

    /** Inserts via the clipboard, then learns the field's real content. */
    private fun pasteAtCaret(
        service: AccessibilityService,
        node: AccessibilityNodeInfo,
        text: String,
    ) {
        val clipboard = service.getSystemService(ClipboardManager::class.java)
        val saved = clipboard.primaryClip
        com.akram.ecosystem.service.ConnectionService.instance?.suppressClipboard(text)
        clipboard.setPrimaryClip(ClipData.newPlainText("Ecosystem", text))
        val pasted = node.performAction(AccessibilityNodeInfo.ACTION_PASTE)
        if (!pasted) {
            Log.w(TAG, "paste rejected; falling back to set-text")
            setFocusedText(node, text)
        }
        handler.postDelayed({
            knownText = service.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                ?.text?.toString() ?: text
            saved?.let { clip ->
                clip.getItemAt(0)?.coerceToText(service)?.toString()?.let {
                    com.akram.ecosystem.service.ConnectionService.instance
                        ?.suppressClipboard(it)
                }
                runCatching { clipboard.setPrimaryClip(clip) }
            }
        }, 150)
    }

    private fun setFocusedText(node: AccessibilityNodeInfo, updated: String) {
        val args = Bundle().apply {
            putCharSequence(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, updated)
        }
        if (node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) {
            knownText = updated.ifEmpty { null }
            node.performAction(
                AccessibilityNodeInfo.ACTION_SET_SELECTION,
                Bundle().apply {
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT,
                        updated.length)
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT,
                        updated.length)
                })
        } else {
            knownText = null
            Log.w(TAG, "ACTION_SET_TEXT rejected by the focused field")
        }
    }

    private fun deleteLastCharacter(service: AccessibilityService) {
        val node = service.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (node == null) {
            Log.w(TAG, "no focused text field")
            return
        }
        val known = knownText
        val current = if (!known.isNullOrEmpty()) {
            node.text?.toString()?.takeIf { it.isNotEmpty() } ?: known
        } else {
            realText(node)
        }
        if (current.isEmpty()) {
            // Nothing there — deleting from a placeholder would type it in.
            knownText = null
            return
        }
        setFocusedText(node, current.dropLast(1))
    }

    /**
     * The field's genuine content, or "" when it is empty and merely showing a
     * placeholder. Where hint metadata is missing, selecting the reported text
     * settles it: a selection can only span characters that are really there,
     * so it fails on an empty field.
     */
    private fun realText(node: AccessibilityNodeInfo): String {
        val raw = node.text?.toString() ?: ""
        if (raw.isEmpty() || node.isShowingHintText) return ""
        if (node.hintText?.toString() == raw) return ""
        val selectable = node.performAction(
            AccessibilityNodeInfo.ACTION_SET_SELECTION,
            Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, raw.length)
            })
        if (!selectable) return ""
        node.performAction(
            AccessibilityNodeInfo.ACTION_SET_SELECTION,
            Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, raw.length)
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, raw.length)
            })
        return raw
    }

    private fun imeEnter(service: AccessibilityService) {
        val node = service.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return
        node.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
    }

    // MARK: keep the screen awake while mirroring

    private var keepAwakeView: View? = null

    /**
     * Android can't capture the screen while the display is physically off, so
     * an invisible overlay with FLAG_KEEP_SCREEN_ON holds the display awake for
     * as long as the Mac is mirroring.
     */
    fun setKeepAwake(enabled: Boolean) {
        val service = service ?: return
        handler.post {
            val wm = service.getSystemService(WindowManager::class.java)
            if (enabled) {
                if (keepAwakeView != null) return@post
                val view = View(service)
                runCatching { wm.addView(view, keepAwakeParams(dimmed)) }
                    .onSuccess { keepAwakeView = view; Log.i(TAG, "keep-awake on") }
                    .onFailure { Log.w(TAG, "keep-awake failed: $it") }
            } else {
                keepAwakeView?.let { runCatching { wm.removeView(it) } }
                keepAwakeView = null
                dimmed = false
                Log.i(TAG, "keep-awake off")
            }
        }
    }

    @Volatile
    private var dimmed = false

    /**
     * Drops the panel to minimum brightness during a session. The phone can't be
     * captured with the display truly off, so "nearly off" is the best Android
     * allows a normal app; the Mac still receives the full-brightness image.
     */
    fun setDimmed(enable: Boolean) {
        dimmed = enable
        val service = service ?: return
        handler.post {
            val view = keepAwakeView ?: return@post
            runCatching {
                service.getSystemService(WindowManager::class.java)
                    .updateViewLayout(view, keepAwakeParams(enable))
            }.onFailure { Log.w(TAG, "dim failed: $it") }
            Log.i(TAG, "dim = $enable")
        }
    }

    private fun keepAwakeParams(dim: Boolean) = WindowManager.LayoutParams(
        1, 1,
        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
        PixelFormat.TRANSPARENT,
    ).apply {
        screenBrightness = if (dim) 0.01f else BRIGHTNESS_OVERRIDE_NONE
    }

    private const val BRIGHTNESS_OVERRIDE_NONE = -1.0f

    private fun dispatch(path: Path, durationMs: Long) {
        val service = service ?: run {
            Log.w(TAG, "no accessibility service; cannot inject touch")
            return
        }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, durationMs))
            .build()
        handler.post {
            runCatching { service.dispatchGesture(gesture, null, null) }
                .onFailure { Log.w(TAG, "dispatchGesture failed: $it") }
        }
    }
}
