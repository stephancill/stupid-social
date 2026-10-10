package net.stupidtech.socialvalidation

import android.content.Context
import android.view.KeyEvent
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView

class StoryKeyboardView(context: Context, appContext: AppContext) : ExpoView(context, appContext) {
  private val onKey by EventDispatcher<Map<String, Any>>()
  init {
    isFocusable = true
    isFocusableInTouchMode = true
    importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
  }
  private var keyboardEnabled = false
  override fun onAttachedToWindow() { super.onAttachedToWindow(); if (keyboardEnabled) requestFocus() }
  fun activate(enabled: Boolean) { keyboardEnabled = enabled; if (enabled) requestFocus() else clearFocus() }
  override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
    val key = when (keyCode) {
      KeyEvent.KEYCODE_DPAD_LEFT -> "left"
      KeyEvent.KEYCODE_DPAD_RIGHT -> "right"
      KeyEvent.KEYCODE_SPACE -> "space"
      else -> return super.onKeyDown(keyCode, event)
    }
    if (event.repeatCount == 0) onKey(mapOf("key" to key, "shift" to event.isShiftPressed))
    return true
  }
}
class StoryKeyboardModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("StoryKeyboard")
    View(StoryKeyboardView::class) {
      Events("onKey")
      Prop("enabled") { view: StoryKeyboardView, enabled: Boolean -> view.activate(enabled) }
    }
  }
}
