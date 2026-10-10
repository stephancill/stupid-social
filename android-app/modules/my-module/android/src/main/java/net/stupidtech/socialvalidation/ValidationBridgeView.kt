package net.stupidtech.socialvalidation

import android.content.Context
import android.webkit.WebView
import android.webkit.WebViewClient
import android.webkit.WebResourceRequest
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import androidx.webkit.ScriptHandler
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView

class ValidationBridgeView(context: Context, appContext: AppContext) : ExpoView(context, appContext) {
  private val onMessage by EventDispatcher<Map<String, String>>()
  private val onLoad by EventDispatcher<Map<String, String>>()
  private val webView = WebView(context)
  private var handler: ScriptHandler? = null
  private var lastConfig: Map<String, String>? = null
  init {
    webView.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    webView.settings.javaScriptEnabled = true
    webView.settings.domStorageEnabled = true
    webView.webViewClient = object : WebViewClient() {
      override fun onPageFinished(view: WebView, url: String) { onLoad(mapOf("url" to url)) }
      override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
        return request.url.scheme !in listOf("http", "https", "about")
      }
    }
    addView(webView)
  }
  fun load(config: Map<String, String>) {
    if (lastConfig == config) return
    lastConfig = config
    handler?.remove()
    val script = config["script"].orEmpty()
    if (script.isNotEmpty()) {
      if (!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT) ||
          !WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
        onMessage(mapOf("data" to "{\"unsupported\":true}"))
        return
      }
      WebViewCompat.removeWebMessageListener(webView, "ValidationCapture")
      val origins = setOf("http://127.0.0.1:8789", "https://open.spotify.com", "https://accounts.spotify.com")
      WebViewCompat.addWebMessageListener(webView, "ValidationCapture", origins) { _, message, _, _, _ ->
        onMessage(mapOf("data" to (message.data ?: "")))
      }
      handler = WebViewCompat.addDocumentStartJavaScript(webView, script, origins)
    }
    webView.loadUrl(requireNotNull(config["url"]))
  }
  fun dispose() { handler?.remove(); webView.destroy() }
}
