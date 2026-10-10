import { Host, Button as NativeButton } from "@expo/ui/swift-ui";
import { disabled as nativeDisabled } from "@expo/ui/swift-ui/modifiers";

import { useTheme } from "@react-navigation/native";
import {
  ActivityIndicator,
  Image,
  Linking,
  Pressable,
  ScrollView,
  Text,
  View,
  type ViewStyle,
  type StyleProp,
} from "react-native";
import type { ReactNode } from "react";
import { errorMessage, networkNames, type Actor, type Network } from "../app/models";
export function Label({
  children,
  muted = false,
  large = false,
}: {
  children: ReactNode;
  muted?: boolean;
  large?: boolean;
}) {
  const { colors } = useTheme();
  return (
    <Text
      style={{
        color: colors.text,
        fontSize: large ? 22 : 16,
        lineHeight: large ? 29 : 23,
        opacity: muted ? 0.62 : 1,
        fontWeight: large ? "600" : "400",
      }}
    >
      {children}
    </Text>
  );
}
export function Page({ children }: { children: ReactNode }) {
  return (
    <ScrollView
      keyboardShouldPersistTaps="handled"
      contentContainerStyle={{ padding: 16, gap: 18, paddingBottom: 40 }}
    >
      {children}
    </ScrollView>
  );
}
export function Row({ children, style }: { children: ReactNode; style?: StyleProp<ViewStyle> }) {
  return (
    <View style={[{ flexDirection: "row", alignItems: "center", gap: 12 }, style]}>{children}</View>
  );
}
export function Button({
  title,
  onPress,
  disabled = false,
  destructive = false,
}: {
  title: string;
  onPress: () => void;
  disabled?: boolean;
  destructive?: boolean;
}) {
  return (
    <Host matchContents>
      <NativeButton
        label={title}
        onPress={onPress}
        role={destructive ? "destructive" : "default"}
        modifiers={[nativeDisabled(disabled)]}
      />
    </Host>
  );
}

export function ErrorNotice({ error }: { error: unknown }) {
  const { colors } = useTheme();
  return error ? (
    <Text
      accessibilityRole="alert"
      style={{ color: colors.notification, fontSize: 14, lineHeight: 21 }}
    >
      {typeof error === "string" ? error : errorMessage({ error })}
    </Text>
  ) : null;
}
export function Busy() {
  return <ActivityIndicator style={{ padding: 20 }} accessibilityLabel="Loading" />;
}
export function Avatar({ actor, size = 44 }: { actor: Actor; size?: number }) {
  const { colors } = useTheme();
  return actor.avatar ? (
    <Image
      source={{ uri: actor.avatar }}
      style={{ width: size, height: size, borderRadius: size / 2, backgroundColor: colors.border }}
      accessibilityLabel={`${actor.name}'s profile picture`}
    />
  ) : (
    <View
      style={{
        width: size,
        height: size,
        borderRadius: size / 2,
        backgroundColor: colors.border,
        alignItems: "center",
        justifyContent: "center",
      }}
    >
      <Label>{(actor.name || actor.username).slice(0, 1).toUpperCase()}</Label>
    </View>
  );
}
export function ActorRow({ actor, onPress }: { actor: Actor; onPress?: () => void }) {
  return (
    <Pressable
      accessibilityRole="button"
      onPress={onPress}
      disabled={!onPress}
      style={{ paddingVertical: 8 }}
    >
      <Row>
        <Avatar actor={actor} />
        <View style={{ flex: 1 }}>
          <Label>{actor.name || actor.username}</Label>
          <Label muted>
            @{actor.username} · {networkNames[actor.network]}
          </Label>
        </View>
      </Row>
    </Pressable>
  );
}
export function NetworkFilter({
  networks,
  value,
  onChange,
}: {
  networks: Network[];
  value?: Network;
  onChange: (value?: Network) => void;
}) {
  const { colors } = useTheme();
  return (
    <ScrollView
      horizontal
      showsHorizontalScrollIndicator={false}
      contentContainerStyle={{ gap: 8, paddingVertical: 8 }}
    >
      {[undefined, ...networks].map((network) => (
        <Pressable
          key={network ?? "all"}
          accessibilityRole="button"
          accessibilityState={{ selected: value === network }}
          onPress={() => onChange(network)}
          style={{
            paddingVertical: 9,
            paddingHorizontal: 14,
            borderRadius: 20,
            backgroundColor: value === network ? colors.border : "transparent",
          }}
        >
          <Label>{network ? networkNames[network] : "All"}</Label>
        </Pressable>
      ))}
    </ScrollView>
  );
}
export async function openURL({ url }: { url: string }) {
  if (new URL(url).protocol !== "https:") return;
  await Linking.openURL(url);
}
