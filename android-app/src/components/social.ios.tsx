import {
  Host,
  Button,
  HStack,
  VStack,
  Spacer,
  Text as NativeText,
  Image as NativeImage,
  RNHostView,
  ZStack,
} from "@expo/ui/swift-ui";
import {
  frame,
  padding,
  font,
  foregroundStyle,
  buttonStyle,
  lineLimit,
} from "@expo/ui/swift-ui/modifiers";
import { useTheme } from "@react-navigation/native";
import { Image, Pressable, StyleSheet, Text, View, type ImageSourcePropType } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import type { ComponentProps } from "react";
import { type Actor, type Network, type SocialNotification, relativeTime } from "../app/models";

import { actorName, notificationCopy } from "../app/presentation";

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
  const symbol = {
    open: "arrow.up.forward.square",
    heart: "heart",
    verified: "checkmark.seal.fill",
  } as const;
  return (
    <Host style={{ width: size + 2, height: size + 2 }} pointerEvents="none">
      <NativeImage systemName={symbol[name]} color={color} modifiers={[font({ size })]} />
    </Host>
  );
}
const storySymbols = {
  close: "xmark",
  "volume-high": "speaker.wave.2.fill",
  "volume-mute": "speaker.slash.fill",
  heart: "heart.fill",
  "heart-outline": "heart",
  "ellipsis-horizontal": "ellipsis",
} as const;
export function useSocialColors() {
  const { dark, colors } = useTheme();
  return {
    dark,
    background: colors.background,
    text: colors.text,
    secondary: dark ? "#98989F" : "#6C6C70",
    tertiary: dark ? "#636366" : "#AEAEB2",
    separator: colors.border,
    fill: dark ? "#1C1C1E" : "#F2F2F7",
    blue: colors.primary,
    error: colors.notification,
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
        minHeight: 36,
        alignItems: "center",
        justifyContent: "center",
        opacity: disabled ? 0.4 : pressed ? 0.5 : 1,
      })}
    >
      {icon === "close" ||
      icon === "volume-high" ||
      icon === "volume-mute" ||
      icon === "heart" ||
      icon === "heart-outline" ||
      icon === "ellipsis-horizontal" ? (
        <Host style={{ width: 20, height: 20 }} pointerEvents="none">
          <NativeImage
            systemName={storySymbols[icon]}
            color={color}
            modifiers={[font({ size: 17, weight: "semibold" }), frame({ width: 20, height: 20 })]}
          />
        </Host>
      ) : (
        <Ionicons name={icon} size={size} color={color} />
      )}
    </Pressable>
  );
}

const eventIcons = {
  reactions: "heart.fill",
  replies: "arrowshape.turn.up.left.fill",
  mentions: "at",
  follows: "person.badge.plus.fill",
  posts: "bubble.left.and.bubble.right.fill",
  messages: "bubble.left.fill",
} as const;
export function NotificationSeparator() {
  const c = useSocialColors();
  return (
    <View
      style={{
        height: 1,
        marginLeft: 56,
        marginRight: 16,
        backgroundColor: c.dark ? "#54545880" : "#3C3C434A",
      }}
    />
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
    copy = notificationCopy({ item });
  const eventColor = {
    reactions: "#FF2D55",
    replies: "#007AFF",
    mentions: "#AF52DE",
    follows: "#34C759",
    posts: c.text,
    messages: "#007AFF",
  }[item.category];
  return (
    <Host matchContents={{ vertical: true }} style={{ minHeight: 80 }}>
      <Button onPress={onPress} modifiers={[buttonStyle("plain")]}>
        <ZStack alignment={copy.preview || copy.image ? "trailing" : "bottomTrailing"}>
          <HStack
            alignment="top"
            spacing={12}
            modifiers={[
              padding({ horizontal: 16, vertical: 20 }),
              frame({ maxWidth: Infinity, alignment: "leading" }),
            ]}
          >
            <NativeImage
              systemName={eventIcons[item.category]}
              color={eventColor}
              modifiers={[
                font({ size: 22, weight: "semibold" }),
                frame({ width: 28, height: 32 }),
                padding({ top: 2 }),
              ]}
            />
            <VStack
              alignment="leading"
              spacing={6}
              modifiers={[frame({ maxWidth: Infinity, alignment: "leading" })]}
            >
              <HStack>
                <RNHostView matchContents>
                  <View
                    style={{
                      height: 32,
                      flexDirection: "row",
                      width: Math.min(item.actors.length, 5) * 26 + 6,
                    }}
                  >
                    {item.actors.slice(0, 5).map((actor, index) => (
                      <View key={actor.id} style={{ marginLeft: index ? -6 : 0 }}>
                        <SocialAvatar actor={actor} />
                      </View>
                    ))}
                  </View>
                </RNHostView>
                <Spacer />
                <NativeText
                  modifiers={[font({ textStyle: "subheadline" }), foregroundStyle(c.secondary)]}
                >
                  {relativeTime({ timestamp: item.timestamp })}
                </NativeText>
              </HStack>
              <HStack spacing={4} modifiers={[padding({ trailing: 24 })]}>
                {copy.leadingActor ? (
                  <RNHostView matchContents>
                    <Image source={networkImages[item.network]} style={{ width: 13, height: 13 }} />
                  </RNHostView>
                ) : null}
                <NativeText
                  modifiers={[font({ textStyle: "body" }), foregroundStyle(c.text), lineLimit(2)]}
                >
                  {copy.leadingActor
                    ? [
                        <NativeText key="actor" modifiers={[font({ weight: "bold" })]}>
                          {copy.actor}
                        </NativeText>,
                        copy.remainder,
                      ]
                    : copy.summary}
                </NativeText>
              </HStack>
              {copy.image ? (
                <RNHostView matchContents>
                  <Image
                    source={{ uri: copy.image }}
                    style={{ width: 48, height: 48, borderRadius: 6 }}
                  />
                </RNHostView>
              ) : copy.preview ? (
                <NativeText
                  modifiers={[
                    font({ textStyle: "subheadline" }),
                    foregroundStyle(c.secondary),
                    lineLimit(2),
                    padding({ trailing: 24 }),
                  ]}
                >
                  {copy.preview}
                </NativeText>
              ) : null}
            </VStack>
          </HStack>
          <NativeImage
            systemName="chevron.forward"
            color={c.dark ? "#FFFFFF4D" : "#3C3C434D"}
            modifiers={[
              font({ textStyle: "body", weight: "semibold" }),
              padding({ trailing: 16, bottom: copy.preview || copy.image ? 0 : 20 }),
            ]}
          />
        </ZStack>
      </Button>
    </Host>
  );
}
