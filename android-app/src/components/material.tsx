import { useColorScheme } from "react-native";
import type { ComponentProps } from "react";
import {
  Host as ComposeHost,
  Box,
  Icon,
  Image,
  Text,
  useMaterialColors,
} from "@expo/ui/jetpack-compose";
import { background, clip, size, Shapes } from "@expo/ui/jetpack-compose/modifiers";
import type { Actor } from "../app/models";
import { actorName } from "../app/presentation";
// Explicit appearance updates existing Compose hosts when Android changes theme in place.
export function NativeHost(props: ComponentProps<typeof ComposeHost>) {
  const colorScheme = useColorScheme();
  return <ComposeHost {...props} colorScheme={colorScheme} />;
}
const icons = {
  search: require("../../assets/material/search.xml"),
  settings: require("../../assets/material/settings.xml"),
  notifications: require("../../assets/material/notifications.xml"),
  notifications_none: require("../../assets/material/notifications_none.xml"),
  close: require("../../assets/material/close.xml"),
  favorite: require("../../assets/material/favorite.xml"),
  reply: require("../../assets/material/reply.xml"),
  alternate_email: require("../../assets/material/alternate_email.xml"),
  person_add: require("../../assets/material/person_add.xml"),
  forum: require("../../assets/material/forum.xml"),
  chat: require("../../assets/material/chat.xml"),
  open_in_new: require("../../assets/material/open_in_new.xml"),
  filter_list: require("../../assets/material/filter_list.xml"),
  verified: require("../../assets/material/verified.xml"),
};
export type MaterialIconName = keyof typeof icons;
export function MaterialIcon({
  name,
  label,
  color,
  iconSize = 24,
}: {
  name: MaterialIconName;
  label?: string;
  color?: string;
  iconSize?: number;
}) {
  return <Icon source={icons[name]} contentDescription={label} tint={color} size={iconSize} />;
}
export function NativeAvatar({ actor, avatarSize = 32 }: { actor: Actor; avatarSize?: number }) {
  const c = useMaterialColors();
  return (
    <Box
      contentAlignment="center"
      modifiers={[
        size(avatarSize, avatarSize),
        clip(Shapes.Circle),
        background(c.surfaceContainerHighest),
      ]}
    >
      {actor.avatar ? (
        <Image
          source={{ uri: actor.avatar }}
          contentScale="crop"
          modifiers={[size(avatarSize, avatarSize)]}
        />
      ) : (
        <Text color={c.onSurfaceVariant}>{actorName({ actor }).slice(0, 1).toUpperCase()}</Text>
      )}
    </Box>
  );
}
