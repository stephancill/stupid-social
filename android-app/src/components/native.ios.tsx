import { View } from "react-native";
import { Host, Button, Image } from "@expo/ui/swift-ui";
import {
  accessibilityLabel,
  disabled as nativeDisabled,
  buttonStyle,
  frame,
} from "@expo/ui/swift-ui/modifiers";
import { MenuView } from "@expo/ui/community/menu";
import { useSocialColors } from "./social";
import type { ComponentProps } from "react";
import type * as Android from "./native";
const icons = {
  "search-outline": "magnifyingglass",
  "settings-outline": "gear",
  notifications: "bell.fill",
  "notifications-outline": "bell",
} as const;
export function ToolbarButton({
  icon,
  label,
  onPress,
  disabled = false,
  badge = false,
}: ComponentProps<typeof Android.ToolbarButton>) {
  const c = useSocialColors();
  return (
    <View style={{ width: 44, height: 44 }}>
      <Host style={{ width: 44, height: 44 }}>
        <Button
          onPress={onPress}
          modifiers={[
            buttonStyle("plain"),
            nativeDisabled(disabled),
            accessibilityLabel(label),
            frame({ width: 44, height: 44 }),
          ]}
        >
          <Image systemName={icons[icon]} size={22} color={c.text} />
        </Button>
      </Host>
      {badge ? (
        <View
          pointerEvents="none"
          style={{
            position: "absolute",
            right: 7,
            top: 6,
            width: 7,
            height: 7,
            borderRadius: 4,
            backgroundColor: c.error,
          }}
        />
      ) : null}
    </View>
  );
}
export function NativeMenu({
  label,
  actions,
  onAction,
}: ComponentProps<typeof Android.NativeMenu>) {
  const c = useSocialColors();
  return (
    <MenuView
      actions={actions}
      colorScheme={c.dark ? "dark" : "light"}
      onPressAction={({ nativeEvent }) => onAction(nativeEvent.event)}
    >
      <Host style={{ width: 36, height: 44 }}>
        <Image
          systemName="line.3.horizontal.decrease"
          size={22}
          color={c.text}
          modifiers={[accessibilityLabel(label), frame({ width: 36, height: 44 })]}
        />
      </Host>
    </MenuView>
  );
}
