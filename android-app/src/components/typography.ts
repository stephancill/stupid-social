import { Platform } from "react-native";

export const androidSmallText = Platform.select({
  android: { fontSize: 14, lineHeight: 20, letterSpacing: 0 },
  default: {},
});
