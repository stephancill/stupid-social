import { useEffect, useRef, useState } from "react";
import {
  AccessibilityInfo,
  Animated,
  Easing,
  Image,
  Pressable,
  Platform,
  ScrollView,
  Text,
  View,
  useWindowDimensions,
} from "react-native";
import { useQuery } from "@tanstack/react-query";
import { LinearGradient } from "expo-linear-gradient";
import { Ionicons } from "@expo/vector-icons";
import type { Account, StoryReel } from "../app/models";
import { actorName, sortedStories } from "../app/presentation";
import { SocialAvatar, useSocialColors } from "./social";
import { androidSmallText } from "./typography";
export function SpinningArtwork({
  uri,
  size,
  playing = true,
  pulse = false,
}: {
  uri?: string;
  size: number;
  playing?: boolean;
  pulse?: boolean;
}) {
  const rotation = useRef(new Animated.Value(0)).current,
    beat = useRef(new Animated.Value(0)).current;
  const motion = useQuery({
    queryKey: ["reduceMotion"],
    queryFn: () => AccessibilityInfo.isReduceMotionEnabled(),
  });
  const [reduced, setReduced] = useState(false);
  useEffect(() => {
    const sub = AccessibilityInfo.addEventListener("reduceMotionChanged", setReduced);
    return () => sub.remove();
  }, []);
  useEffect(() => {
    if (!playing || motion.data || reduced) return;
    const spin = Animated.loop(
      Animated.timing(rotation, {
        toValue: 1,
        duration: 8889,
        easing: Easing.linear,
        useNativeDriver: true,
      }),
    );
    const rhythm = Animated.loop(
      Animated.timing(beat, {
        toValue: 1,
        duration: 1111,
        easing: Easing.linear,
        useNativeDriver: true,
      }),
    );
    spin.start();
    if (pulse) rhythm.start();
    return () => {
      spin.stop();
      rhythm.stop();
    };
  }, [playing, motion.data, reduced, rotation, beat, pulse]);
  return (
    <View style={{ width: size, height: size, alignItems: "center", justifyContent: "center" }}>
      {pulse ? (
        <Animated.View
          style={{
            position: "absolute",
            width: size * 0.93,
            height: size * 0.93,
            borderRadius: size / 2,
            backgroundColor: "white",
            opacity: beat.interpolate({ inputRange: [0, 1], outputRange: [0.22, 0] }),
            transform: [{ scale: beat.interpolate({ inputRange: [0, 1], outputRange: [1, 1.3] }) }],
          }}
        />
      ) : null}
      <Animated.View
        style={{
          width: size,
          height: size,
          borderRadius: size / 2,
          overflow: "hidden",
          backgroundColor: "#ffffff15",
          transform: [
            {
              rotate: rotation.interpolate({ inputRange: [0, 1], outputRange: ["0deg", "360deg"] }),
            },
          ],
        }}
      >
        {uri ? (
          <Image source={{ uri }} style={{ width: size, height: size }} />
        ) : (
          <View style={{ flex: 1, alignItems: "center", justifyContent: "center" }}>
            <Ionicons
              name="musical-note"
              size={size / 4}
              color={size > 100 ? "#ffffff50" : "#1fba42"}
            />
          </View>
        )}
      </Animated.View>
    </View>
  );
}
export function StoryBar({
  reels,
  account,
  onOpen,
  onCompose,
  preview,
}: {
  reels: StoryReel[];
  account?: Account;
  onOpen: (reels: StoryReel[], index: number) => void;
  onCompose: () => void;
  preview: boolean;
}) {
  const c = useSocialColors(),
    { fontScale } = useWindowDimensions();
  const specific = (["instagram", "spotify", "github"] as const).filter(
    (network) => reels.some((r) => r.network === network) || (network === "instagram" && account),
  );
  const modes = specific.length > 1 ? ["all", ...specific] : specific;
  const pages = modes.length > 1 ? [modes[modes.length - 1]!, ...modes, modes[0]!] : modes;
  const height = (Platform.OS === "android" ? 128 : 112) * Math.max(1, fontScale),
    pager = useRef<ScrollView>(null),
    [selected, setSelected] = useState(0);
  const key = modes.join(":");
  useEffect(() => {
    setSelected(0);
    requestAnimationFrame(() =>
      pager.current?.scrollTo({ y: modes.length > 1 ? height : 0, animated: false }),
    );
  }, [key, height, modes.length]);
  const own = reels.find((r) => r.network === "instagram" && r.actor.id === account?.id);
  const items = sortedStories({ reels: reels.filter((r) => r !== own) });
  if (!modes.length) return null;
  return (
    <View style={{ paddingVertical: 8 }}>
      <ScrollView
        ref={pager}
        nestedScrollEnabled
        pagingEnabled
        showsVerticalScrollIndicator={false}
        style={{ height }}
        onMomentumScrollEnd={({ nativeEvent }) => {
          let page = Math.round(nativeEvent.contentOffset.y / height);
          if (modes.length > 1) {
            if (page === 0) {
              page = modes.length;
              pager.current?.scrollTo({ y: page * height, animated: false });
            } else if (page === pages.length - 1) {
              page = 1;
              pager.current?.scrollTo({ y: height, animated: false });
            }
            setSelected(page - 1);
          }
        }}
      >
        {pages.map((mode, page) => {
          const row = items.filter((r) => mode === "all" || r.network === mode);
          return (
            <View
              key={`${page}:${mode}`}
              style={{ height }}
              accessibilityElementsHidden={page !== selected + (modes.length > 1 ? 1 : 0)}
              importantForAccessibility={
                page === selected + (modes.length > 1 ? 1 : 0) ? "auto" : "no-hide-descendants"
              }
            >
              <Text
                style={{
                  marginHorizontal: 16,
                  fontSize: 12,
                  lineHeight: 15,
                  ...androidSmallText,
                  fontWeight: "600",
                  color: c.secondary,
                  includeFontPadding: false,
                }}
              >
                {mode === "all"
                  ? "All Stories"
                  : mode === "instagram"
                    ? "Instagram"
                    : mode === "spotify"
                      ? "Spotify"
                      : "GitHub"}
              </Text>
              <ScrollView
                horizontal
                nestedScrollEnabled
                showsHorizontalScrollIndicator={false}
                contentContainerStyle={{
                  gap: 12,
                  paddingHorizontal: 16,
                  paddingTop: 8,
                  paddingBottom: 4,
                }}
              >
                {account && (mode === "all" || mode === "instagram") ? (
                  <View style={{ width: 70 }}>
                    <Pressable
                      accessibilityLabel={own ? "Your Instagram story" : "Create story"}
                      accessibilityRole="button"
                      disabled={preview && !own}
                      onPress={() => (own ? onOpen([own], 0) : onCompose())}
                    >
                      <Bubble reel={own} account={account} />
                    </Pressable>
                    <Pressable
                      accessibilityRole="button"
                      accessibilityLabel="Create Instagram story"
                      disabled={preview}
                      onPress={onCompose}
                      hitSlop={10}
                      style={{
                        position: "absolute",
                        left: 49,
                        top: 49,
                        width: 26,
                        height: 26,
                        borderRadius: 13,
                        backgroundColor: c.blue,
                        borderWidth: 2,
                        borderColor: c.background,
                        alignItems: "center",
                        justifyContent: "center",
                      }}
                    >
                      <Ionicons name="add" size={19} color="white" />
                    </Pressable>
                  </View>
                ) : null}
                {row.map((reel) => (
                  <Pressable
                    key={reel.id}
                    accessibilityRole="button"
                    accessibilityLabel={`${reel.network === "spotify" ? "Listening activity" : reel.network === "github" ? "GitHub activity" : "Instagram stories"} from ${actorName({ actor: reel.actor })}${reel.seen ? ", seen" : ""}`}
                    onPress={() => {
                      const visible = row.filter((r) => r.seen === reel.seen);
                      onOpen(
                        visible,
                        visible.findIndex((r) => r.id === reel.id),
                      );
                    }}
                  >
                    <Bubble reel={reel} />
                  </Pressable>
                ))}
              </ScrollView>
            </View>
          );
        })}
      </ScrollView>
      {modes.length > 1 ? (
        <View style={{ position: "absolute", left: 4, top: "40%", gap: 5 }} pointerEvents="none">
          {modes.map((mode, index) => (
            <View
              key={mode}
              style={{
                width: selected === index ? 7 : 5,
                height: selected === index ? 7 : 5,
                borderRadius: 4,
                backgroundColor: c.secondary,
                opacity: selected === index ? 1 : 0.25,
                alignSelf: "center",
              }}
            />
          ))}
        </View>
      ) : null}
    </View>
  );
}
function Bubble({ reel, account }: { reel?: StoryReel; account?: Account }) {
  const c = useSocialColors(),
    actor = reel?.actor ?? account!,
    spotify = reel?.network === "spotify";
  const name = spotify ? actor.name || actor.username : actorName({ actor });
  return (
    <View style={{ width: 70, gap: 6, alignItems: "center" }}>
      <View style={{ width: 70, height: 70 }}>
        {reel?.network === "instagram" && !reel.seen ? (
          <LinearGradient
            colors={["#af52de", "#ff2d88", "#ff9500"]}
            start={{ x: 0, y: 0 }}
            end={{ x: 1, y: 1 }}
            style={{ position: "absolute", inset: -1.5, borderRadius: 38 }}
          />
        ) : null}
        <View style={{ margin: reel?.network === "instagram" && !reel.seen ? 1.5 : 0 }}>
          {spotify ? (
            <SpinningArtwork uri={reel?.thumbnail} size={70} />
          ) : (
            <SocialAvatar
              actor={actor}
              size={reel?.network === "instagram" && !reel.seen ? 67 : 70}
              border={!reel}
            />
          )}
        </View>
        {reel && (reel.seen || reel.network !== "instagram") ? (
          <View
            pointerEvents="none"
            style={{
              position: "absolute",
              inset: -1.5,
              borderRadius: 38,
              borderWidth: 3,
              borderColor: reel.seen ? "#80808066" : spotify ? "#1fba42" : c.text,
            }}
          />
        ) : null}
        {spotify ? (
          <View style={{ position: "absolute", right: -3, bottom: -3 }}>
            <SocialAvatar actor={actor} size={28} />
          </View>
        ) : reel?.closeFriends ? (
          <View
            style={{
              position: "absolute",
              right: -3,
              bottom: -3,
              width: 24,
              height: 24,
              borderRadius: 12,
              backgroundColor: "#34c759",
              borderWidth: 2,
              borderColor: c.background,
              alignItems: "center",
              justifyContent: "center",
            }}
          >
            <Ionicons name="star" size={13} color="white" />
          </View>
        ) : null}
      </View>
      <Text
        numberOfLines={1}
        style={{
          width: 70,
          textAlign: "center",
          color: c.text,
          fontSize: Platform.OS === "ios" ? 11 : 12,
          lineHeight: Platform.OS === "ios" ? 13 : 15,
          ...androidSmallText,
          includeFontPadding: false,
        }}
      >
        {name}
      </Text>
    </View>
  );
}
