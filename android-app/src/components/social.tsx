import {
  ListItem,
  HorizontalDivider,
  Column,
  Row as NativeRow,
  Box,
  Text as NativeText,
  Image as NativeImage,
  useMaterialColors,
} from "@expo/ui/jetpack-compose";
import {
  clickable,
  fillMaxWidth,
  weight,
  size,
  clip,
  background,
  padding,
  Shapes,
} from "@expo/ui/jetpack-compose/modifiers";
import { useTheme } from "@react-navigation/native";
import { Image, Pressable, StyleSheet, Text, View, type ImageSourcePropType } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import type { ComponentProps } from "react";
import { type Actor, type Network, type SocialNotification, relativeTime } from "../app/models";
import { NativeHost, MaterialIcon, NativeAvatar, type MaterialIconName } from "./material";
import { actorName, notificationCopy } from "../app/presentation";
import { androidSmallText } from "./typography";

export type IconName = ComponentProps<typeof Ionicons>["name"];
export function InlineIcon({
  name,
  color,
  size,
}: {
  name: "open" | "heart" | "verified";
  color: string;
  size: number;
}) {
  return (
    <Ionicons
      name={
        name === "open" ? "open-outline" : name === "heart" ? "heart-outline" : "checkmark-circle"
      }
      size={size}
      color={color}
    />
  );
}
export function useSocialColors() {
  const { dark } = useTheme();
  const m = useMaterialColors();
  // Keep six-digit strings because custom story artwork adds its own alpha.
  return {
    dark,
    background: m.surface.slice(0, 7),
    text: m.onSurface.slice(0, 7),
    secondary: m.onSurfaceVariant.slice(0, 7),
    tertiary: m.outline.slice(0, 7),
    separator: m.outlineVariant.slice(0, 7),
    fill: m.surfaceContainer.slice(0, 7),
    blue: m.primary.slice(0, 7),
    error: m.error.slice(0, 7),
  };
}
export const networkImages: Record<Network, ImageSourcePropType> = {
  x: require("../../assets/networks/XBadge.png"),
  farcaster: require("../../assets/networks/FarcasterBadge.png"),
  instagram: require("../../assets/networks/InstagramBadge.png"),
  bluesky: require("../../assets/networks/BlueskyBadge.png"),
  github: require("../../assets/networks/GitHubBadge.png"),
  spotify: require("../../assets/networks/SpotifyBadge.png"),
};
export function SocialAvatar({
  actor,
  size = 32,
  border = true,
}: {
  actor: Actor;
  size?: number;
  border?: boolean;
}) {
  const c = useSocialColors();
  return (
    <View
      style={{
        width: size,
        height: size,
        borderRadius: size / 2,
        backgroundColor: c.fill,
        overflow: "hidden",
        alignItems: "center",
        justifyContent: "center",
      }}
    >
      {actor.avatar ? (
        <Image source={{ uri: actor.avatar }} style={StyleSheet.absoluteFill} />
      ) : (
        <Text
          style={{
            fontSize: size >= 80 ? 28 : size >= 60 ? 20 : 12,
            fontWeight: "600",
            color: c.secondary,
            includeFontPadding: false,
          }}
        >
          {actorName({ actor }).slice(0, 1).toUpperCase()}
        </Text>
      )}
      {border ? (
        <View
          pointerEvents="none"
          style={[
            StyleSheet.absoluteFill,
            { borderRadius: size / 2, borderWidth: 1, borderColor: c.secondary + "40" },
          ]}
        />
      ) : null}
    </View>
  );
}
export function IconButton({
  icon,
  label,
  onPress,
  color = "white",
  disabled = false,
  size = 19,
}: {
  icon: IconName;
  label: string;
  onPress: () => void;
  color?: string;
  disabled?: boolean;
  size?: number;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      onPress={onPress}
      disabled={disabled}
      hitSlop={5}
      style={({ pressed }) => ({
        minWidth: 36,
        minHeight: 44,
        alignItems: "center",
        justifyContent: "center",
        opacity: disabled ? 0.4 : pressed ? 0.5 : 1,
      })}
    >
      <Ionicons name={icon} size={size} color={color} />
    </Pressable>
  );
}
const eventIcons: Record<
  SocialNotification["category"],
  { icon: MaterialIconName; color: string }
> = {
  reactions: { icon: "favorite", color: "#ff2d55" },
  replies: { icon: "reply", color: "#009dff" },
  mentions: { icon: "alternate_email", color: "#af52de" },
  follows: { icon: "person_add", color: "#34c759" },
  posts: { icon: "forum", color: "" },
  messages: { icon: "chat", color: "#009dff" },
};
const feedText = {
  regular: { fontSize: 16, lineHeight: 20, letterSpacing: 0 },
  small: androidSmallText,
};
export function NotificationSeparator() {
  const c = useSocialColors();
  return (
    <NativeHost style={{ height: 1, marginStart: 56, marginEnd: 16 }}>
      <HorizontalDivider thickness={1} color={c.dark ? "#54545880" : "#3C3C434A"} />
    </NativeHost>
  );
}
export function NotificationRow({
  item,
  onPress,
}: {
  item: SocialNotification;
  onPress: () => void;
}) {
  const c = useSocialColors(),
    copy = notificationCopy({ item }),
    event = eventIcons[item.category];
  return (
    <NativeHost matchContents={{ vertical: true }} style={{ minHeight: 80 }}>
      <ListItem modifiers={[fillMaxWidth(), clickable(onPress)]}>
        <ListItem.LeadingContent>
          <MaterialIcon name={event.icon} color={event.color || c.text} />
        </ListItem.LeadingContent>
        <ListItem.HeadlineContent>
          <Column verticalArrangement={{ spacedBy: 6 }}>
            <NativeRow
              horizontalArrangement="spaceBetween"
              verticalAlignment="center"
              modifiers={[fillMaxWidth()]}
            >
              <NativeRow horizontalArrangement={{ spacedBy: -6 }}>
                {item.actors.slice(0, 5).map((actor) => (
                  <NativeAvatar key={actor.id} actor={actor} />
                ))}
                {item.actors.length > 5 ? (
                  <Box
                    contentAlignment="center"
                    modifiers={[size(32, 32), clip(Shapes.Circle), background(c.fill)]}
                  >
                    <NativeText color={c.secondary} style={feedText.small}>
                      +{item.actors.length - 5}
                    </NativeText>
                  </Box>
                ) : null}
              </NativeRow>
              <NativeText color={c.secondary} style={feedText.small}>
                {relativeTime({ timestamp: item.timestamp })}
              </NativeText>
            </NativeRow>
            <NativeRow horizontalArrangement={{ spacedBy: 4 }} verticalAlignment="center">
              {copy.leadingActor ? (
                <NativeImage
                  source={networkImages[item.network] as number}
                  modifiers={[size(13, 13)]}
                />
              ) : null}
              <NativeText
                maxLines={2}
                overflow="ellipsis"
                modifiers={[weight(1)]}
                style={feedText.regular}
              >
                {copy.leadingActor
                  ? [
                      <NativeText key="actor" style={{ fontWeight: "bold" }}>
                        {copy.actor}
                      </NativeText>,
                      copy.remainder,
                    ]
                  : copy.summary}
              </NativeText>
            </NativeRow>
          </Column>
        </ListItem.HeadlineContent>
        {copy.image || copy.preview ? (
          <ListItem.SupportingContent>
            <Box modifiers={[padding(0, 6, 0, 0)]}>
              {copy.image ? (
                <NativeImage
                  source={{ uri: copy.image }}
                  contentScale="crop"
                  modifiers={[size(48, 48)]}
                />
              ) : (
                <NativeText
                  maxLines={2}
                  overflow="ellipsis"
                  color={c.secondary}
                  style={feedText.regular}
                >
                  {copy.preview}
                </NativeText>
              )}
            </Box>
          </ListItem.SupportingContent>
        ) : null}
      </ListItem>
    </NativeHost>
  );
}
