import { useColorScheme } from "react-native";
import { DarkTheme, DefaultTheme } from "@react-navigation/native";
import { useMaterialColors } from "@expo/ui/jetpack-compose";
export function useAppTheme() {
  const base = useColorScheme() === "dark" ? DarkTheme : DefaultTheme;
  const material = useMaterialColors();
  return {
    ...base,
    colors: {
      ...base.colors,
      background: material.surface,
      card: material.surface,
      text: material.onSurface,
      border: material.outlineVariant,
      primary: material.primary,
      notification: material.error,
    },
  };
}
