import { View } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { Badge, BadgedBox, IconButton } from "@expo/ui/jetpack-compose";
import { MenuView, type MenuAction } from "@expo/ui/community/menu";
import { useSocialColors } from "./social";

import { NativeHost, MaterialIcon } from "./material";
const toolbarIcons = {
  "search-outline": "search",
  "settings-outline": "settings",
  notifications: "notifications",
  "notifications-outline": "notifications_none",
} as const;
export function ToolbarButton({
  icon,
  label,
  onPress,
  disabled = false,
  badge = false,
}: {
  icon: keyof typeof toolbarIcons;
  label: string;
  onPress: () => void;
  disabled?: boolean;
  badge?: boolean;
}) {
  const c = useSocialColors();
  return (
    <NativeHost style={{ width: 48, height: 48 }}>
      <IconButton onClick={onPress} enabled={!disabled}>
        {badge ? (
          <BadgedBox>
            <MaterialIcon name={toolbarIcons[icon]} label={label} color={c.text} />
            <BadgedBox.Badge>
              <Badge />
            </BadgedBox.Badge>
          </BadgedBox>
        ) : (
          <MaterialIcon name={toolbarIcons[icon]} label={label} color={c.text} />
        )}
      </IconButton>
    </NativeHost>
  );
}
export function NativeMenu({
  label,
  actions,
  onAction,
}: {
  label: string;
  actions: MenuAction[];
  onAction: (id: string) => void;
}) {
  const c = useSocialColors();
  return (
    <MenuView
      colorScheme={c.dark ? "dark" : "light"}
      actions={actions}
      onPressAction={({ nativeEvent }) => onAction(nativeEvent.event)}
    >
      <View
        accessible
        accessibilityRole="button"
        accessibilityLabel={label}
        style={{ width: 48, height: 48, alignItems: "center", justifyContent: "center" }}
      >
        <Ionicons name="filter-outline" size={24} color={c.text} />
      </View>
    </MenuView>
  );
}
