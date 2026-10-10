import { useColorScheme } from "react-native";
import { DarkTheme, DefaultTheme } from "@react-navigation/native";
export function useAppTheme() {
  const dark = useColorScheme() === "dark";
  const base = dark ? DarkTheme : DefaultTheme;
  return {
    ...base,
    colors: {
      ...base.colors,
      background: dark ? "#000000" : "#FFFFFF",
      card: dark ? "#000000" : "#FFFFFF",
      primary: dark ? "#0A84FF" : "#007AFF",
      text: dark ? "#FFFFFF" : "#000000",
      border: dark ? "#38383A" : "#C6C6C8",
      notification: "#FF3B30",
    },
  };
}
