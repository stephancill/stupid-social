import { requireNativeModule, requireNativeView } from "expo";
import { WebView } from "react-native-webview";
import type { ComponentProps } from "react";
import type * as Android from "./bridge";

export const bridge = requireNativeModule<typeof Android.bridge>("ValidationBridge");
export function EarlyWebView({
  config,
  onMessage,
  onLoad,
  ...props
}: ComponentProps<typeof Android.EarlyWebView>) {
  return (
    <WebView
      {...props}
      source={{ uri: config.url }}
      injectedJavaScriptBeforeContentLoaded={config.script}
      onMessage={onMessage}
      onLoad={(event) => onLoad?.({ nativeEvent: { url: event.nativeEvent.url } })}
      sharedCookiesEnabled
    />
  );
}
export const StoryKeyboard =
  requireNativeView<ComponentProps<typeof Android.StoryKeyboard>>("StoryKeyboard");
