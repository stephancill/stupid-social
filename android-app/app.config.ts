import type { ConfigContext, ExpoConfig } from "expo/config";

export default function appConfig({ config }: ConfigContext): ExpoConfig {
  return {
    ...config,
    name: "stupid social",
    platforms: ["android", "ios"],
    ios: {
      ...config.ios,
      bundleIdentifier: "net.stupidtech.socialexpo",
      supportsTablet: false,
      infoPlist: { ...config.ios?.infoPlist, CFBundleDisplayName: "Social Expo" },
    },
    slug: "stupid-social",
    plugins: [
      ...(config.plugins ?? []),
      "expo-video",
      ["expo-audio", { recordAudioAndroid: false }],
      ["expo-image-picker", { cameraPermission: false, microphonePermission: false }],
      [
        "expo-media-library",
        { granularPermissions: ["photo"], isAccessMediaLocationEnabled: false },
      ],
    ],
    android: {
      ...config.android,
      icon: "./assets/android-icon.png",
      adaptiveIcon: {
        foregroundImage: "./assets/android-icon-foreground.png",
        monochromeImage: "./assets/android-icon-foreground.png",
        backgroundColor: "#FFFFFF",
      },
      // The development ID preserves the account used for the Android validation.
      package:
        process.env.APP_VARIANT === "production"
          ? "net.stupidtech.stupidsocial"
          : "net.stupidtech.socialvalidation",
      allowBackup: false,
    },
  };
}
