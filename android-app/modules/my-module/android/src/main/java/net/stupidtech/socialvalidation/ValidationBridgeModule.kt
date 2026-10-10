package net.stupidtech.socialvalidation

import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.webkit.CookieManager
import android.webkit.WebView
import androidx.webkit.WebViewFeature
import expo.modules.kotlin.Promise
import expo.modules.kotlin.functions.Queues
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import java.io.ByteArrayOutputStream
import java.io.File
import android.util.Base64

class ValidationBridgeModule : Module() {
  private fun context() = requireNotNull(appContext.reactContext)
  override fun definition() = ModuleDefinition {
    Name("ValidationBridge")
    Function("environment") {
      mapOf("webView" to (WebView.getCurrentWebViewPackage()?.versionName ?: "unknown"),
        "documentStart" to WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT),
        "messageListener" to WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER))
    }
    AsyncFunction("cookies") { url: String ->
      require(java.net.URI(url).host in setOf("x.com", "www.instagram.com", "github.com", "open.spotify.com", "accounts.spotify.com", "127.0.0.1"))
      CookieManager.getInstance().getCookie(url) ?: ""
    }.runOnQueue(Queues.MAIN)
    AsyncFunction("seedCookie") { url: String, value: String, promise: Promise ->
      require(java.net.URI(url).host in setOf("x.com", "www.instagram.com", "github.com", "open.spotify.com", "accounts.spotify.com", "127.0.0.1"))
      CookieManager.getInstance().setCookie(url, value) { accepted ->
        CookieManager.getInstance().flush()
        if (accepted) promise.resolve(null) else promise.reject("COOKIE_REJECTED", "Android rejected the selected cookie.", null)
      }
    }.runOnQueue(Queues.MAIN)
    AsyncFunction("importSeed") {
      check(context().applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0)
      val file = File(context().filesDir, "validation-seed.json")
      if (!file.exists()) null else file.readText().also { check(file.delete()) }
    }
    AsyncFunction("writeReport") { json: String ->
      File(context().filesDir, "validation-report.json").writeText(json)
    }
    AsyncFunction("testImage") {
      val bitmap = Bitmap.createBitmap(1080, 1920, Bitmap.Config.ARGB_8888)
      val canvas = Canvas(bitmap)
      canvas.drawColor(Color.WHITE)
      val paint = Paint().apply { color = Color.BLACK; textSize = 48f; isAntiAlias = true }
      canvas.drawText("Android validation", 100f, 900f, paint)
      val bytes = ByteArrayOutputStream()
      bitmap.compress(Bitmap.CompressFormat.JPEG, 90, bytes)
      bitmap.recycle()
      Base64.encodeToString(bytes.toByteArray(), Base64.NO_WRAP)
    }
    View(ValidationBridgeView::class) {
      Events("onMessage", "onLoad")
      Prop("config") { view: ValidationBridgeView, config: Map<String, String> -> view.load(config) }
      OnViewDestroys { view: ValidationBridgeView -> view.dispose() }
    }
  }
}
