import { StatusBar } from "expo-status-bar";
import { useIsFocused } from "@react-navigation/native";
import { useEffect, useRef, useState } from "react";
import {
  ActivityIndicator,
  Alert,
  AppState,
  Image,
  PanResponder,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  View,
  useWindowDimensions,
} from "react-native";
import { useQuery, useMutation } from "@tanstack/react-query";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { useVideoPlayer, VideoView } from "expo-video";
import { useAudioPlayer, useAudioPlayerStatus } from "expo-audio";
import { LinearGradient } from "expo-linear-gradient";
import { Ionicons } from "@expo/vector-icons";
import { StoryKeyboard } from "../bridge";
import { type ScreenProps } from "../app/navigation";
import { type StorySlide, relativeTime, errorMessage } from "../app/models";
import { actorName } from "../app/presentation";
import { markSeen } from "../app/storage";
import { queryClient, refreshFeed } from "../app/services";
import {
  instagramReel,
  instagramStorySeen,
  instagramStoryLike,
  instagramDelete,
} from "../instagram/client";
import { spotifyPreview, spotifySaved, spotifySave } from "../providers/spotify";
import { githubRepo, githubProfile } from "../github/client";
import { openURL } from "../components/ui";
import { IconButton, SocialAvatar, type IconName } from "../components/social";
import { SpinningArtwork } from "../components/StoryBar";

function Pill({
  title,
  icon = "open-outline",
  onPress,
  disabled = false,
  translucent = true,
}: {
  title: string;
  icon?: IconName;
  onPress: () => void;
  disabled?: boolean;
  translucent?: boolean;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={title}
      disabled={disabled}
      onPress={onPress}
      style={{
        flexDirection: "row",
        gap: 8,
        alignItems: "center",
        justifyContent: "center",
        paddingHorizontal: translucent ? 12 : 20,
        height: translucent ? 34 : 44,
        borderRadius: 24,
        backgroundColor: translucent ? "#00000073" : "#ffffff1f",
        borderWidth: translucent ? 1 : 0,
        borderColor: "#ffffff24",
        opacity: disabled ? 0.5 : 1,
        maxWidth: "100%",
      }}
    >
      <Ionicons name={icon} size={translucent ? 13 : 19} color="white" />
      <Text
        numberOfLines={1}
        style={{
          color: "white",
          fontSize: translucent ? 12 : 15,
          fontWeight: "500",
          flexShrink: 1,
          includeFontPadding: false,
        }}
      >
        {title}
      </Text>
    </Pressable>
  );
}
function StoryVideo({
  uri,
  playing,
  muted,
  onEnd,
  onProgress,
  onReady,
}: {
  uri: string;
  playing: boolean;
  muted: boolean;
  onEnd: () => void;
  onProgress: (time: number, duration: number) => void;
  onReady: () => void;
}) {
  const player = useVideoPlayer(uri, (p) => {
    p.loop = false;
    p.timeUpdateEventInterval = 0.1;
  });
  const [error, setError] = useState(false),
    callbacks = useRef({ onEnd, onProgress, onReady });
  callbacks.current = { onEnd, onProgress, onReady };
  useEffect(() => {
    player.muted = muted;
    if (playing) player.play();
    else player.pause();
  }, [player, playing, muted]);
  useEffect(() => {
    if (player.status === "readyToPlay") callbacks.current.onReady();
    const a = player.addListener("playToEnd", () => callbacks.current.onEnd()),
      b = player.addListener("timeUpdate", (e) =>
        callbacks.current.onProgress(e.currentTime, player.duration),
      ),
      c = player.addListener("statusChange", (e) => {
        if (e.status === "readyToPlay") callbacks.current.onReady();
        if (e.status === "error") {
          setError(true);
          callbacks.current.onReady();
        }
      });
    return () => {
      a.remove();
      b.remove();
      c.remove();
    };
  }, [player]);
  return (
    <>
      <VideoView
        player={player}
        contentFit="contain"
        surfaceType="textureView"
        nativeControls={false}
        style={StyleSheet.absoluteFill}
      />
      {error ? (
        <Text style={styles.error}>This video couldn't load. Tap right to continue.</Text>
      ) : null}
    </>
  );
}
function StoryAudio({
  uri,
  playing,
  muted,
  onStatus,
}: {
  uri: string;
  playing: boolean;
  muted: boolean;
  onStatus?: (time: number, duration: number, loaded: boolean) => void;
}) {
  const player = useAudioPlayer(uri, { updateInterval: 100 }),
    status = useAudioPlayerStatus(player),
    callback = useRef(onStatus);
  callback.current = onStatus;
  useEffect(() => {
    player.muted = muted;
    if (playing) player.play();
    else player.pause();
  }, [player, playing, muted]);
  useEffect(() => {
    callback.current?.(status.currentTime, status.duration, status.isLoaded);
  }, [status.currentTime, status.duration, status.isLoaded]);
  return null;
}
function SpotifyStory({
  slide,
  playing,
  muted,
  preview,
  onReady,
  onProgress,
  onEnd,
}: {
  slide: StorySlide;
  playing: boolean;
  muted: boolean;
  preview: boolean;
  onReady: () => void;
  onProgress: (time: number, duration: number) => void;
  onEnd: () => void;
}) {
  const audio = useQuery({
    queryKey: ["spotifyPreview", slide.trackId],
    queryFn: () => spotifyPreview({ trackId: slide.trackId! }),
    enabled: !!slide.trackId && !preview,
  });
  const saved = useQuery({
    queryKey: ["spotifySaved", slide.trackId],
    queryFn: () => spotifySaved({ trackId: slide.trackId! }),
    enabled: !!slide.trackId && !preview,
  });
  const save = useMutation({
    mutationFn: () => spotifySave({ trackId: slide.trackId!, saved: !saved.data }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["spotifySaved", slide.trackId] }),
    onError: (error) => Alert.alert("Couldn't update Liked Songs", errorMessage({ error })),
  });
  const ready = useRef(onReady);
  ready.current = onReady;
  const [loaded, setLoaded] = useState(false);
  useEffect(() => {
    if (preview || !slide.trackId || audio.isError || (audio.isSuccess && !audio.data))
      ready.current();
  }, [preview, slide.trackId, audio.isError, audio.isSuccess, audio.data]);
  const size = Math.min(280, useWindowDimensions().width - 80);
  return (
    <View style={{ flex: 1, alignItems: "center", justifyContent: "center", gap: 32 }}>
      <SpinningArtwork uri={slide.image} size={size} playing={playing} pulse />
      <View
        style={{
          height: 84,
          paddingHorizontal: 32,
          gap: 4,
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <Text
          numberOfLines={2}
          style={{
            color: "white",
            fontSize: 20,
            lineHeight: 25,
            fontWeight: "600",
            textAlign: "center",
            includeFontPadding: false,
          }}
        >
          {slide.title}
          {slide.artist ? ` — ${slide.artist}` : ""}
        </Text>
        {slide.text ? (
          <Text
            numberOfLines={1}
            style={{ color: "#ffffff99", fontSize: 15, includeFontPadding: false }}
          >
            {slide.text}
          </Text>
        ) : null}
        {slide.context && slide.context !== slide.text ? (
          <Text numberOfLines={1} style={{ color: "#ffffff80", fontSize: 12 }}>
            From {slide.context}
          </Text>
        ) : null}
      </View>
      <View style={{ flexDirection: "row", gap: 12, alignItems: "center" }}>
        {slide.url ? (
          <Pill
            title="Open in Spotify"
            translucent={false}
            onPress={() => void openURL({ url: slide.url! })}
          />
        ) : null}
        {slide.trackId ? (
          <Pressable
            accessibilityRole="button"
            accessibilityLabel={saved.data ? "Remove from Liked Songs" : "Save track"}
            disabled={preview || save.isPending || saved.isPending || saved.isError}
            onPress={() => save.mutate()}
            style={{
              width: 44,
              height: 44,
              borderRadius: 22,
              backgroundColor: saved.data ? "#34c759" : "#ffffff1f",
              alignItems: "center",
              justifyContent: "center",
            }}
          >
            {save.isPending ? (
              <ActivityIndicator color="white" />
            ) : (
              <Ionicons name={saved.data ? "checkmark" : "add"} size={22} color="white" />
            )}
          </Pressable>
        ) : null}
      </View>
      {!preview && audio.data ? (
        <StoryAudio
          uri={audio.data}
          playing={playing}
          muted={muted}
          onStatus={(time, duration, isLoaded) => {
            if (isLoaded && !loaded) {
              setLoaded(true);
              ready.current();
            }
            if (duration > 0) {
              onProgress(time, duration);
              if (time >= duration - 0.05) onEnd();
            }
          }}
        />
      ) : null}
    </View>
  );
}
function GitHubStory({ slide, preview }: { slide: StorySlide; preview: boolean }) {
  const meta = slide.github,
    kind =
      meta?.kind ??
      (slide.text.includes("followed")
        ? "followed"
        : slide.text.includes("forked")
          ? "forked"
          : slide.text.includes("created")
            ? "created"
            : "starred"),
    following = kind === "followed";
  const repo = useQuery({
    queryKey: ["repo", slide.url],
    queryFn: () => githubRepo({ url: slide.url! }),
    enabled: !following && !!slide.url && !preview && (!meta?.description || kind === "forked"),
  });
  const original = useQuery({
    queryKey: ["repo", repo.data?.parentURL],
    queryFn: () => githubRepo({ url: repo.data!.parentURL! }),
    enabled: kind === "forked" && !!repo.data?.parentURL && !preview,
  });
  const profile = useQuery({
    queryKey: ["githubStoryProfile", slide.title],
    queryFn: () => githubProfile({ username: slide.title! }),
    enabled: following && !preview && !!slide.title && !meta?.bio,
  });
  const target =
    kind === "forked" && original.data
      ? original.data.url.replace("https://github.com/", "")
      : (slide.title ?? "Repository");
  const avatar =
    meta?.avatar ??
    (slide.title ? `https://github.com/${target.split("/")[0]}.png?size=192` : undefined);
  const description = following
    ? (meta?.bio ?? profile.data?.bio)
    : kind === "forked" && original.data
      ? original.data.text
      : (meta?.description ?? repo.data?.text);
  const action: IconName = following
    ? "person-add-outline"
    : kind === "forked"
      ? "git-branch"
      : kind === "created"
        ? "folder-open-outline"
        : "star";
  return (
    <View style={{ flex: 1 }}>
      <View style={{ flex: 1, justifyContent: "center", gap: 14 }}>
        <View style={{ height: 195, justifyContent: "center", paddingHorizontal: 24 }}>
          <View
            style={{
              padding: 20,
              gap: 14,
              backgroundColor: "#ffffff14",
              borderRadius: 18,
              borderWidth: 1,
              borderColor: "#ffffff1f",
            }}
          >
            <View style={{ flexDirection: "row", gap: 12, alignItems: "center" }}>
              <Image
                source={avatar ? { uri: avatar } : undefined}
                style={{
                  width: following ? 48 : 40,
                  height: following ? 48 : 40,
                  borderRadius: 24,
                  backgroundColor: "#ffffff14",
                }}
              />
              <View style={{ flex: 1, gap: 2 }}>
                <Text numberOfLines={1} style={{ color: "white", fontWeight: "600", fontSize: 17 }}>
                  {following ? (meta?.name ?? profile.data?.name ?? target) : target}
                </Text>
                {following ? (
                  <Text style={{ color: "#ffffff99", fontSize: 12 }}>@{target}</Text>
                ) : null}
              </View>
              {!following && meta?.stars ? (
                <View style={{ flexDirection: "row", alignItems: "center", gap: 4 }}>
                  <Ionicons name="star" size={12} color="#ffcc00" />
                  <Text style={{ color: "#ffffffe6", fontSize: 15, fontWeight: "600" }}>
                    {meta.stars}
                  </Text>
                </View>
              ) : null}
            </View>
            {description ? (
              <Text
                numberOfLines={following ? 3 : 4}
                style={{ color: "#ffffffd1", fontSize: 15, lineHeight: 20 }}
              >
                {description}
              </Text>
            ) : null}
            {following ? (
              <View style={{ flexDirection: "row", gap: 16 }}>
                <Text style={styles.stat}>
                  {meta?.repos ?? profile.data?.posts ?? "–"}{" "}
                  <Text style={{ color: "#ffffff99" }}>Repositories</Text>
                </Text>
                <Text style={styles.stat}>
                  {meta?.followers ?? profile.data?.followers ?? "–"}{" "}
                  <Text style={{ color: "#ffffff99" }}>Followers</Text>
                </Text>
              </View>
            ) : meta?.language ? (
              <View style={{ flexDirection: "row", gap: 6, alignItems: "center" }}>
                <View
                  style={{
                    width: 8,
                    height: 8,
                    borderRadius: 4,
                    backgroundColor: meta.languageColor ?? "#ffffffb3",
                  }}
                />
                <Text style={{ color: "#ffffffb3", fontSize: 15 }}>{meta.language}</Text>
              </View>
            ) : null}
          </View>
        </View>
        <Ionicons name={action} size={22} color="#ffffffe6" style={{ alignSelf: "center" }} />
        <Text
          style={{
            color: "#ffffffd1",
            fontSize: 15,
            lineHeight: 20,
            fontWeight: "500",
            textAlign: "center",
            paddingHorizontal: 32,
          }}
        >
          {kind === "forked" && original.data
            ? slide.text.replace(slide.title ?? "", target)
            : slide.text}
        </Text>
      </View>
      <View style={{ alignItems: "center", paddingBottom: 44 }}>
        {slide.url ? (
          <Pill
            title="Open on GitHub"
            translucent={false}
            onPress={() => void openURL({ url: original.data?.url ?? slide.url! })}
          />
        ) : null}
      </View>
    </View>
  );
}
let viewerMuted = false;
export function StoriesScreen({ route, navigation }: ScreenProps<"Stories">) {
  const focused = useIsFocused(),
    insets = useSafeAreaInsets(),
    { width, height } = useWindowDimensions();
  const { reels, preview = false } = route.params,
    [index, setIndex] = useState(route.params.index),
    [position, setPosition] = useState(0),
    [paused, setPaused] = useState(false),
    [muted, setMuted] = useState(viewerMuted),
    [active, setActive] = useState(true),
    [readyId, setReadyId] = useState<string>(),
    [elapsed, setElapsed] = useState(0),
    [duration, setDuration] = useState(5),
    [mediaClock, setMediaClock] = useState(false),
    [actions, setActions] = useState(false),
    reel = reels[index]!;
  const loaded = useQuery({
    queryKey: ["story", reel.id],
    queryFn: () => instagramReel({ username: reel.actor.username }),
    enabled: reel.network === "instagram" && !preview,
  });
  const slides = reel.network === "instagram" && !preview ? (loaded.data ?? []) : reel.slides,
    slide = slides[position];
  const nextPerson = () => {
    if (index + 1 < reels.length) {
      setIndex(index + 1);
      setPosition(0);
    } else navigation.goBack();
  };
  const previousPerson = () => {
    if (index > 0) {
      setIndex(index - 1);
      setPosition(0);
    }
  };
  const next = () => {
    if (position + 1 < slides.length) setPosition(position + 1);
    else nextPerson();
  };
  const previous = () => {
    if (position > 0) setPosition(position - 1);
    else previousPerson();
  };
  const navigationRef = useRef({ next, previous, nextPerson, previousPerson });
  navigationRef.current = { next, previous, nextPerson, previousPerson };
  const playbackId = `${reel.id}:${slide?.id}`,
    ready = readyId === playbackId;
  const clockId = useRef<string | undefined>(undefined);
  const setReady = (value: boolean) => setReadyId(value ? playbackId : undefined);
  const timerReady =
    reel.network !== "instagram" || (!!slide && ((!slide.image && !slide.video) || ready));
  const playing = !paused && active && focused && !actions;
  useEffect(() => {
    clockId.current = undefined;
    setElapsed(0);
    setDuration(slide?.duration ?? 5);
    setMediaClock(false);
    setActions(false);
  }, [slide?.id, index, slide?.duration]);
  useEffect(() => {
    const sub = AppState.addEventListener("change", (s) => setActive(s === "active"));
    return () => sub.remove();
  }, []);
  useEffect(() => {
    if (!slide || !playing || !timerReady || mediaClock || (reel.network === "spotify" && !ready))
      return;
    const timer = setInterval(() => {
      clockId.current = playbackId;
      setElapsed((value) => value + 0.1);
    }, 100);
    return () => clearInterval(timer);
  }, [slide, playing, timerReady, mediaClock, reel.network, ready, playbackId]);
  const advanced = useRef<string | undefined>(undefined);
  useEffect(() => {
    if (
      slide &&
      clockId.current === playbackId &&
      elapsed >= duration &&
      advanced.current !== playbackId
    ) {
      advanced.current = `${reel.id}:${slide.id}`;
      navigationRef.current.next();
    }
  }, [elapsed, duration, slide, reel.id, playbackId]);
  useEffect(() => {
    advanced.current = undefined;
  }, [slide?.id, index]);
  const seen = useMutation({
    mutationFn: async ({ current }: { current: StorySlide }) => {
      if (preview) return;
      if (reel.network === "instagram" && current.ownerId !== reel.accountId)
        await instagramStorySeen({ slide: current });
      if (position === slides.length - 1) await markSeen({ reel });
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["feed"] }),
  });
  const observed = useRef(new Set<string>());
  useEffect(() => {
    if (slide && timerReady && !observed.current.has(`${reel.id}:${slide.id}`)) {
      observed.current.add(`${reel.id}:${slide.id}`);
      seen.mutate({ current: slide });
    }
  }, [slide, timerReady, reel.id, seen]);
  const like = useMutation({
    mutationFn: () => instagramStoryLike({ slide: slide!, liked: !slide!.liked }),
    onSuccess: () =>
      queryClient.setQueryData<StorySlide[]>(["story", reel.id], (old) =>
        old?.map((s) => (s.id === slide!.id ? { ...s, liked: !s.liked } : s)),
      ),
    onError: (error) => Alert.alert("Like Failed", errorMessage({ error })),
  });
  const remove = useMutation({
    mutationFn: () => instagramDelete({ slide: slide! }),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["story", reel.id] });
      await refreshFeed();
      navigation.goBack();
    },
    onError: (error) => Alert.alert("Delete Failed", errorMessage({ error })),
  });
  const touch = useRef({ started: 0, paused: false, x: 0 });
  const pan = PanResponder.create({
    onStartShouldSetPanResponder: () => true,
    onPanResponderGrant: (e) => {
      touch.current = { started: Date.now(), paused, x: e.nativeEvent.locationX };
      if (reel.network !== "spotify") setPaused(true);
    },
    onPanResponderRelease: (_, gesture) => {
      setPaused(touch.current.paused);
      if (gesture.dy > 80) navigation.goBack();
      else if (gesture.dx < -50) nextPerson();
      else if (gesture.dx > 50) previousPerson();
      else if (
        Math.abs(gesture.dx) < 20 &&
        Math.abs(gesture.dy) < 20 &&
        Date.now() - touch.current.started < 350
      ) {
        if (touch.current.x < width / 2) previous();
        else next();
      }
    },
    onPanResponderTerminate: () => setPaused(touch.current.paused),
  });
  const progress = (time: number, length: number) => {
    if (length > 0) {
      clockId.current = playbackId;
      setMediaClock(true);
      setElapsed(time);
      setDuration(length);
    }
  };
  const own = slide?.ownerId === reel.accountId;
  return (
    <View style={{ flex: 1, backgroundColor: "black" }}>
      <StatusBar style={focused ? "light" : "auto"} />
      <StoryKeyboard
        style={{ position: "absolute", width: 1, height: 1 }}
        enabled={active && focused}
        onKey={({ nativeEvent: event }) => {
          if (event.key === "space") setPaused((value) => !value);
          else if (event.shift) {
            if (event.key === "right") nextPerson();
            else previousPerson();
          } else if (event.key === "right") next();
          else previous();
        }}
      />
      <View style={{ flex: 1, marginTop: insets.top, marginBottom: insets.bottom }}>
        {slide && reel.network === "instagram" ? (
          <View style={StyleSheet.absoluteFill}>
            {slide.video ? (
              <StoryVideo
                key={slide.id}
                uri={slide.video}
                playing={playing}
                muted={muted}
                onEnd={() => {
                  if (advanced.current !== `${reel.id}:${slide.id}`) {
                    advanced.current = `${reel.id}:${slide.id}`;
                    next();
                  }
                }}
                onReady={() => setReady(true)}
                onProgress={progress}
              />
            ) : slide.image ? (
              <Image
                key={slide.id}
                source={{ uri: slide.image }}
                style={StyleSheet.absoluteFill}
                resizeMode="contain"
                onLoad={() => setReady(true)}
                onError={() => setReady(true)}
              />
            ) : (
              <View style={{ flex: 1, justifyContent: "center", padding: 32 }}>
                <Text style={{ color: "white", fontSize: 22, textAlign: "center" }}>
                  {slide.text}
                </Text>
              </View>
            )}
            {slide.audio && !slide.video ? (
              <StoryAudio uri={slide.audio} playing={playing} muted={muted} />
            ) : null}
          </View>
        ) : slide && reel.network === "spotify" ? (
          <SpotifyStory
            key={slide.id}
            slide={slide}
            playing={playing}
            muted={muted}
            preview={preview}
            onReady={() => setReady(true)}
            onProgress={progress}
            onEnd={() => {
              if (advanced.current !== `${reel.id}:${slide.id}`) {
                advanced.current = `${reel.id}:${slide.id}`;
                next();
              }
            }}
          />
        ) : slide ? (
          <GitHubStory slide={slide} preview={preview} />
        ) : null}
        <View
          {...pan.panHandlers}
          accessible
          accessibilityRole="adjustable"
          accessibilityLabel="Story. Tap left or right to navigate, hold to pause, swipe down to close"
          accessibilityActions={[
            { name: "increment", label: "Next story" },
            { name: "decrement", label: "Previous story" },
            { name: "activate", label: paused ? "Play story" : "Pause story" },
          ]}
          onAccessibilityAction={({ nativeEvent }) =>
            nativeEvent.actionName === "increment"
              ? next()
              : nativeEvent.actionName === "decrement"
                ? previous()
                : setPaused(!paused)
          }
          style={{
            position: "absolute",
            left: 0,
            right: 0,
            top: 76,
            bottom:
              reel.network === "instagram"
                ? slide?.title || slide?.mentions.length || slide?.links.length
                  ? 140
                  : 0
                : reel.network === "spotify"
                  ? height * 0.43
                  : 155,
          }}
        />
        {slide && reel.network === "instagram" ? (
          <View
            pointerEvents="box-none"
            style={{
              position: "absolute",
              left: 24,
              right: 24,
              bottom: 42,
              alignItems: "center",
              gap: 10,
            }}
          >
            {slide.title ? (
              <View
                style={{
                  alignSelf: "stretch",
                  flexDirection: "row",
                  alignItems: "center",
                  gap: 10,
                  paddingHorizontal: 12,
                  paddingVertical: 10,
                  borderRadius: 14,
                  borderWidth: 1,
                  borderColor: "#ffffff24",
                  backgroundColor: "#00000073",
                }}
              >
                {slide.artwork ? (
                  <Image
                    source={{ uri: slide.artwork }}
                    style={{ width: 36, height: 36, borderRadius: 7 }}
                  />
                ) : null}
                <Ionicons name="musical-note" size={16} color="#ffffffd1" />
                <View style={{ flex: 1, gap: 1 }}>
                  <Text
                    numberOfLines={1}
                    style={{ color: "white", fontSize: 15, fontWeight: "600" }}
                  >
                    {slide.title}
                  </Text>
                  {slide.artist ? (
                    <Text numberOfLines={1} style={{ color: "#ffffffb8", fontSize: 12 }}>
                      {slide.artist}
                    </Text>
                  ) : null}
                </View>
              </View>
            ) : null}
            <View
              style={{ flexDirection: "row", gap: 8, flexWrap: "wrap", justifyContent: "center" }}
            >
              {slide.mentions.slice(0, 3).map((actor) => (
                <Pill
                  key={actor.id}
                  icon="person-circle-outline"
                  title={`@${actor.username}`}
                  onPress={() => {
                    setPaused(true);
                    navigation.navigate("Profile", { actor, preview });
                  }}
                />
              ))}
              {slide.links
                .filter((url) => url !== slide.embedURL)
                .slice(0, 2)
                .map((url) => (
                  <Pill
                    key={url}
                    icon="link"
                    title={slide.linkTitles[url] ?? "Open link"}
                    onPress={() => {
                      setPaused(true);
                      void openURL({ url });
                    }}
                  />
                ))}
            </View>
            {slide.embedURL ? (
              <Pill
                title={slide.embedLabel ?? "Open post"}
                onPress={() => {
                  setPaused(true);
                  void openURL({ url: slide.embedURL! });
                }}
              />
            ) : null}
          </View>
        ) : null}
        {!slide && !loaded.error ? <ActivityIndicator color="white" style={{ flex: 1 }} /> : null}
        {loaded.error || seen.error ? (
          <Text style={styles.error}>{errorMessage({ error: loaded.error || seen.error })}</Text>
        ) : null}
        <LinearGradient
          colors={["#0000008c", "#00000000"]}
          style={{
            position: "absolute",
            left: 0,
            right: 0,
            top: 0,
            paddingTop: 10,
            paddingBottom: 12,
            gap: 12,
          }}
        >
          <View style={{ flexDirection: "row", gap: 4, paddingHorizontal: 8 }}>
            {slides.map((s, i) => (
              <View
                key={s.id}
                style={{
                  flex: 1,
                  height: 3,
                  borderRadius: 2,
                  backgroundColor: ready || timerReady ? "#ffffff4d" : "#80808047",
                  overflow: "hidden",
                }}
              >
                <View
                  style={{
                    height: 3,
                    borderRadius: 2,
                    backgroundColor: "white",
                    width:
                      i < position
                        ? "100%"
                        : i === position
                          ? `${Math.min(100, (elapsed / duration) * 100)}%`
                          : "0%",
                  }}
                />
              </View>
            ))}
          </View>
          <View
            style={{ flexDirection: "row", gap: 10, alignItems: "center", paddingHorizontal: 16 }}
          >
            <Pressable
              accessibilityRole="button"
              accessibilityLabel="Open profile"
              onPress={() => {
                setPaused(true);
                navigation.navigate("Profile", { actor: reel.actor, preview });
              }}
            >
              <SocialAvatar actor={reel.actor} size={36} border={false} />
            </Pressable>
            <View style={{ flex: 1, gap: 1 }}>
              <Text
                numberOfLines={1}
                style={{
                  color: "white",
                  fontSize: 17,
                  lineHeight: Platform.OS === "ios" ? 20 : 22,
                  fontWeight: "600",
                  includeFontPadding: false,
                }}
              >
                {reel.network === "spotify" ? reel.actor.name : actorName({ actor: reel.actor })}
              </Text>
              <Text
                style={{
                  color: "#ffffffb3",
                  fontSize: 12,
                  lineHeight: Platform.OS === "ios" ? 14 : 16,
                  includeFontPadding: false,
                }}
              >
                {relativeTime({ timestamp: slide?.timestamp ?? reel.timestamp })}
              </Text>
            </View>
            <View style={{ flexDirection: "row", gap: 10 }}>
              {reel.network === "instagram" && slide && !own && !preview ? (
                <IconButton
                  icon={slide.liked ? "heart" : "heart-outline"}
                  label={slide.liked ? "Unlike story" : "Like story"}
                  color={slide.liked ? "#ff3b30" : "white"}
                  disabled={preview || like.isPending}
                  onPress={() => like.mutate()}
                />
              ) : null}
              {reel.network === "instagram" && own ? (
                <IconButton
                  icon="ellipsis-horizontal"
                  label="Story actions"
                  disabled={preview || remove.isPending}
                  onPress={() => setActions(!actions)}
                />
              ) : null}
              <IconButton
                icon={muted ? "volume-mute" : "volume-high"}
                label={muted ? "Unmute story" : "Mute story"}
                onPress={() => {
                  viewerMuted = !muted;
                  setMuted(!muted);
                }}
              />
              <IconButton
                icon="close"
                size={24}
                label="Close"
                onPress={() => navigation.goBack()}
              />
            </View>
          </View>
        </LinearGradient>
        {actions ? (
          <View style={[StyleSheet.absoluteFill, { alignItems: "flex-end" }]}>
            <Pressable
              accessibilityLabel="Dismiss story actions"
              onPress={() => setActions(false)}
              style={StyleSheet.absoluteFill}
            />
            <Pressable
              accessibilityRole="button"
              accessibilityLabel="Delete story"
              onPress={() => {
                setActions(false);
                setPaused(true);
                Alert.alert("Delete Story?", "This removes it from Instagram.", [
                  { text: "Cancel", style: "cancel", onPress: () => setPaused(false) },
                  { text: "Delete Story", style: "destructive", onPress: () => remove.mutate() },
                ]);
              }}
              style={{
                marginTop: 58,
                marginRight: 54,
                width: 170,
                flexDirection: "row",
                alignItems: "center",
                gap: 8,
                paddingHorizontal: 14,
                paddingVertical: 11,
                borderRadius: 14,
                backgroundColor: "#272727f2",
                borderWidth: 1,
                borderColor: "#ffffff1f",
              }}
            >
              <Ionicons name="trash-outline" size={16} color="#ff453a" />
              <Text style={{ color: "#ff453a", fontSize: 15, fontWeight: "600" }}>Delete</Text>
            </Pressable>
          </View>
        ) : null}
      </View>
    </View>
  );
}
const styles = StyleSheet.create({
  error: {
    position: "absolute",
    bottom: 12,
    left: 24,
    right: 24,
    color: "#ffb4ab",
    fontSize: 13,
    textAlign: "center",
  },
  stat: { color: "white", fontSize: 15, fontWeight: "600" },
});
