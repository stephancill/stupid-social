import { requireNativeModule, requireNativeView } from "expo";
import type { ViewProps } from "react-native";

export const bridge = requireNativeModule<{
  environment(): { webView: string; documentStart: boolean; messageListener: boolean };
  cookies(url: string): Promise<string>;
  seedCookie(url: string, value: string): Promise<void>;
  importSeed(): Promise<string | null>;
  writeReport(json: string): Promise<void>;
  testImage(): Promise<string>;
}>("ValidationBridge");

export const EarlyWebView = requireNativeView<
  ViewProps & {
    config: { url: string; script: string };
    onMessage: (event: { nativeEvent: { data: string } }) => void;
    onLoad?: (event: { nativeEvent: { url: string } }) => void;
  }
>("ValidationBridge");

export const StoryKeyboard = requireNativeView<
  ViewProps & {
    enabled: boolean;
    onKey: (event: { nativeEvent: { key: string; shift: boolean } }) => void;
  }
>("StoryKeyboard");
