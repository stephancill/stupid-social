import { useEffect, useRef, useState, type ReactNode } from "react";
import {
  ActivityIndicator,
  Platform,
  Alert,
  BackHandler,
  Image,
  Keyboard,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
  useWindowDimensions,
} from "react-native";
import { useIsFocused, useTheme } from "@react-navigation/native";
import { useMutation, useQuery } from "@tanstack/react-query";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { StoryIcon, type StoryIconName } from "../components/StoryIcon";
import { CaptionAccessory } from "../components/CaptionAccessory";
import { LinearGradient } from "expo-linear-gradient";
import { StatusBar } from "expo-status-bar";
import * as ImagePicker from "expo-image-picker";
import * as MediaLibrary from "expo-media-library";
import { captureRef } from "react-native-view-shot";
import { File } from "expo-file-system";
import type { ScreenProps } from "../app/navigation";
import { type Actor, errorMessage, socialError } from "../app/models";
import {
  captionInTrash,
  captionMentions,
  exportTextLayout,
  insertMention,
  mentionToken,
  type Caption,
} from "../app/composer";
import { instagramPublish, instagramSearch } from "../instagram/client";
import { refreshFeed } from "../app/services";
import {
  StoryCaption,
  captionBackgrounds,
  captionColors,
  captionFonts,
} from "../components/StoryCaption";

const backgrounds: {
  name: string;
  colors: readonly [string, string, ...string[]];
  vertical?: boolean;
}[] = [
  { name: "Black", colors: ["#000000", "#000000"] },
  { name: "White", colors: ["#FFFFFF", "#FFFFFF"] },
  { name: "Blue", colors: ["#007AFF", "#007AFF"] },
  { name: "Purple", colors: ["#AF52DE", "#AF52DE"] },
  { name: "Sunset", colors: ["#FF9500", "#FF2D55", "#AF52DE"] },
  { name: "Ocean", colors: ["#32ADE6", "#007AFF", "#5856D6"], vertical: true },
  { name: "Graphite", colors: ["#000000", "#8E8E93"] },
];
function Background({ index }: { index: number }) {
  const background = backgrounds[index]!;
  return (
    <LinearGradient
      colors={background.colors}
      start={{ x: background.vertical ? 0.5 : 0, y: 0 }}
      end={{ x: background.vertical ? 0.5 : 1, y: 1 }}
      style={StyleSheet.absoluteFill}
    />
  );
}
function Tool({
  label,
  icon,
  children,
  onPress,
  disabled = false,
  loading = false,
  value,
}: {
  label: string;
  icon?: StoryIconName;
  children?: ReactNode;
  onPress: () => void;
  disabled?: boolean;
  loading?: boolean;
  value?: string;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityValue={value ? { text: value } : undefined}
      accessibilityState={{ disabled, busy: loading }}
      disabled={disabled || loading}
      onPress={onPress}
      style={({ pressed }) => [styles.tool, { opacity: disabled || pressed ? 0.5 : 1 }]}
    >
      {loading ? (
        <ActivityIndicator color="white" size="small" />
      ) : (
        (children ?? <StoryIcon name={icon!} size={24} color="white" />)
      )}
    </Pressable>
  );
}
function Swatch({ color }: { color: string }) {
  return <View style={[styles.swatch, { backgroundColor: color }]} />;
}

export function ComposerScreen({ navigation }: ScreenProps<"Composer">) {
  const screen = useWindowDimensions(),
    insets = useSafeAreaInsets(),
    focused = useIsFocused(),
    { dark } = useTheme();
  const [viewport, setViewport] = useState({ width: screen.width, height: screen.height });
  const [availableHeight, setAvailableHeight] = useState(screen.height);
  const [keyboardTop, setKeyboardTop] = useState<number>();
  const width = viewport.width,
    height = Math.max(1, viewport.height - insets.top - insets.bottom);
  const canvas = useRef<View>(null);
  const [image, setImage] = useState<string>();
  const [loadedImage, setLoadedImage] = useState<string>();
  const [background, setBackground] = useState(0);
  const [captions, setCaptions] = useState<Caption[]>([]);
  const [selected, setSelected] = useState<string>();
  const [selection, setSelection] = useState<{ start: number; end: number }>();
  const [dragged, setDragged] = useState<Caption>();
  const [saved, setSaved] = useState(false);
  const [debounced, setDebounced] = useState<string>();
  const caption = captions.find((item) => item.id === selected);
  const token = caption
    ? mentionToken({ text: caption.text, cursor: selection?.end ?? caption.text.length })
    : undefined;
  const query = token?.query;
  const hasContent = !!image || captions.length > 0 || background !== 0;
  const imageReady = !image || loadedImage === image;
  const exportSize = { width, height: (width * 16) / 9 };
  const exportText = exportTextLayout({ canvas: { width, height }, output: exportSize });
  const toolbarTop = Math.min(availableHeight, keyboardTop ?? viewport.height - insets.bottom) - 56;
  const overTrash = dragged ? captionInTrash({ ...dragged, width, height }) : false;

  function finishEditing() {
    setSelected(undefined);
    setSelection(undefined);
    Keyboard.dismiss();
  }
  useEffect(() => {
    const shown = Keyboard.addListener("keyboardDidShow", (event) =>
      setKeyboardTop(event.endCoordinates.screenY),
    );
    const hidden = Keyboard.addListener("keyboardDidHide", () => {
      setKeyboardTop(undefined);
      if (Platform.OS !== "ios") {
        setSelected(undefined);
        setSelection(undefined);
      }
    });
    return () => {
      shown.remove();
      hidden.remove();
    };
  }, []);
  useEffect(() => {
    if (!selected) return;
    const back = BackHandler.addEventListener("hardwareBackPress", () => {
      finishEditing();
      return true;
    });
    return () => back.remove();
  }, [selected]);
  useEffect(() => {
    const timer = setTimeout(() => setDebounced(query), 250);
    return () => clearTimeout(timer);
  }, [query]);
  useEffect(() => {
    if (!saved) return;
    const timer = setTimeout(() => setSaved(false), 1400);
    return () => clearTimeout(timer);
  }, [saved]);
  const search = useQuery({
    queryKey: ["mentionSearch", debounced],
    queryFn: () => instagramSearch({ query: debounced! }),
    enabled: !!selected && query !== undefined && query === debounced && !!debounced,
  });
  const results = query && query === debounced ? (search.data?.slice(0, 8) ?? []) : [];
  function showError(error: unknown) {
    Alert.alert("Story Image", errorMessage({ error }));
  }
  const pendingPhoto = useQuery({
    queryKey: ["pendingStoryPhoto"],
    queryFn: () => ImagePicker.getPendingResultAsync(),
    staleTime: 0,
    gcTime: 0,
  });
  useEffect(() => {
    const result = pendingPhoto.data;
    if (result && "assets" in result && result.assets?.[0]) setImage(result.assets[0].uri);
  }, [pendingPhoto.data]);
  useEffect(() => {
    if (pendingPhoto.error) showError(pendingPhoto.error);
  }, [pendingPhoto.error]);
  const pick = useMutation({
    mutationFn: () => ImagePicker.launchImageLibraryAsync({ mediaTypes: ["images"], quality: 1 }),
    onSuccess: (result) => {
      if (!result.canceled && result.assets[0]) setImage(result.assets[0].uri);
    },
    onError: showError,
  });
  function update(next: Caption) {
    setCaptions((old) => old.map((item) => (item.id === next.id ? next : item)));
  }
  function remove(id: string) {
    setCaptions((old) => old.filter((item) => item.id !== id));
    if (selected === id) finishEditing();
  }
  function addText() {
    const id = String(Date.now());
    setCaptions((old) => [
      ...old,
      {
        id,
        text: "Text",
        x: 0.5,
        y: 0.5,
        scale: 1,
        background: 0,
        font: 0,
        color: 0,
        mentions: [],
      },
    ]);
    setSelected(id);
    setSelection({ start: 0, end: 4 });
  }
  function chooseMention(actor: Actor) {
    if (!caption) return;
    const result = insertMention({ caption, cursor: selection?.end ?? caption.text.length, actor });
    if (!result) return;
    update(result.caption);
    setSelection({ start: result.cursor, end: result.cursor });
  }
  async function render() {
    if (!imageReady) throw socialError({ message: "Wait for the photo to finish loading." });
    finishEditing();
    await new Promise<void>((resolve) =>
      requestAnimationFrame(() => requestAnimationFrame(() => resolve())),
    );
    return captureRef(canvas, {
      format: "jpg",
      quality: 0.94,
      width: 1080,
      height: 1920,
      result: "tmpfile",
    });
  }
  const save = useMutation({
    mutationFn: async () => {
      const uri = await render();
      try {
        const permission = await MediaLibrary.requestPermissionsAsync(true, ["photo"]);
        if (!permission.granted)
          throw socialError({ message: "Allow photo access to save your story." });
        await MediaLibrary.Asset.create(uri);
      } finally {
        new File(uri).delete();
      }
    },
    onSuccess: () => setSaved(true),
    onError: showError,
  });
  const publish = useMutation({
    mutationFn: async () => {
      const uri = await render();
      try {
        await instagramPublish({ uri, mentions: captionMentions({ captions }) });
      } finally {
        new File(uri).delete();
      }
    },
    onSuccess: async () => {
      await refreshFeed();
      navigation.goBack();
    },
    onError: showError,
  });
  const busy = save.isPending || publish.isPending || pick.isPending;
  return (
    <View
      style={styles.root}
      onLayout={(event) => {
        const layout = event.nativeEvent.layout;
        setAvailableHeight(layout.height);
        // Keep the composition stationary when Android resizes the window for its keyboard.
        setViewport((old) =>
          layout.width !== old.width ||
          (!Keyboard.isVisible() && !selected) ||
          layout.height > old.height
            ? { width: layout.width, height: layout.height }
            : old,
        );
      }}
    >
      <StatusBar style={focused ? "light" : dark ? "light" : "dark"} />
      <Background index={background} />
      <View style={{ position: "absolute", top: insets.top, width, height }}>
        <Pressable accessible={false} style={StyleSheet.absoluteFill} onPress={finishEditing}>
          {image ? (
            <Image source={{ uri: image }} resizeMode="contain" style={StyleSheet.absoluteFill} />
          ) : null}
          {!hasContent ? (
            <View style={styles.empty}>
              <StoryIcon name="photo-library" size={46} color="#FFFFFF85" />
              <Text style={styles.placeholder}>Select an image or add text to start</Text>
            </View>
          ) : null}
        </Pressable>
        {selected ? (
          <View
            pointerEvents="none"
            style={[StyleSheet.absoluteFill, { backgroundColor: "#00000075", zIndex: 1 }]}
          />
        ) : null}
        {captions.map((item) => (
          <StoryCaption
            key={item.id}
            caption={item}
            width={width}
            height={height}
            editing={selected === item.id}
            selection={selected === item.id ? selection : undefined}
            onSelection={setSelection}
            onChange={update}
            disabled={busy}
            onEdit={() => {
              setSelected(item.id);
              setSelection(undefined);
            }}
            onDrag={setDragged}
            onDragEnd={(value) => {
              if (captionInTrash({ ...value, width, height })) remove(value.id);
            }}
            onDelete={() => remove(item.id)}
          />
        ))}
        {dragged ? (
          <View
            pointerEvents="none"
            style={[
              styles.trash,
              {
                left: width / 2 - 38,
                backgroundColor: overTrash ? "#FF3B30" : "#0000008C",
                borderColor: overTrash ? "#FFFFFFE6" : "#FFFFFF59",
                transform: [{ scale: overTrash ? 1.12 : 1 }],
              },
            ]}
          >
            <StoryIcon name="delete-outline" size={28} color="white" />
          </View>
        ) : null}
      </View>
      <View pointerEvents="box-none" style={[styles.top, { top: insets.top + 16 }]}>
        <Tool
          label="Close composer"
          icon="close"
          disabled={busy}
          onPress={() => {
            finishEditing();
            navigation.goBack();
          }}
        />
        <View style={styles.tools}>
          <Tool
            label="Select image"
            icon="image"
            disabled={busy}
            onPress={() => {
              finishEditing();
              pick.mutate();
            }}
          />
          <Tool label="Add text" disabled={busy} onPress={addText}>
            <Text style={[styles.textIcon, { fontSize: 18, fontWeight: "600" }]}>Aa</Text>
          </Tool>
          <Tool
            label="Change background color"
            value={backgrounds[background]!.name}
            disabled={busy}
            onPress={() => setBackground((value) => (value + 1) % backgrounds.length)}
          >
            <View style={styles.swatch}>
              <Background index={background} />
            </View>
          </Tool>
          {hasContent ? (
            <Tool
              label="Save story image"
              icon={saved ? "check" : "save-alt"}
              disabled={busy || !imageReady}
              loading={save.isPending}
              onPress={() => save.mutate()}
            />
          ) : null}
        </View>
      </View>
      {hasContent && !dragged ? (
        <View
          pointerEvents="box-none"
          style={[
            styles.postContainer,
            {
              top:
                viewport.height -
                insets.bottom -
                72 -
                (Platform.OS !== "ios" && selected && keyboardTop === undefined ? 56 : 0),
            },
          ]}
        >
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="Post story"
            accessibilityState={{ disabled: busy || !imageReady }}
            disabled={busy || !imageReady}
            style={({ pressed }) => [styles.post, { opacity: pressed || busy ? 0.6 : 1 }]}
            onPress={() =>
              Alert.alert(
                "Post this story?",
                "Your story will be visible to your Instagram audience.",
                [
                  { text: "Cancel", style: "cancel" },
                  { text: "Post", onPress: () => publish.mutate() },
                ],
              )
            }
          >
            {publish.isPending ? (
              <ActivityIndicator color="white" />
            ) : (
              <StoryIcon name="send" size={20} color="white" />
            )}
            <Text style={styles.postText}>{publish.isPending ? "Posting..." : "Post Story"}</Text>
          </Pressable>
        </View>
      ) : null}
      {caption ? (
        <>
          {token ? (
            <View
              style={[
                styles.suggestions,
                {
                  bottom: undefined,
                  top: toolbarTop - (results.length ? 112 : 44) - 10,
                  height: results.length ? 112 : 44,
                },
              ]}
            >
              {results.length ? (
                <ScrollView
                  horizontal
                  keyboardShouldPersistTaps="always"
                  showsHorizontalScrollIndicator={false}
                  contentContainerStyle={styles.suggestionContent}
                >
                  {results.map((actor) => (
                    <Pressable
                      key={actor.id}
                      accessibilityRole="button"
                      accessibilityLabel={`Mention @${actor.username}`}
                      onPress={() => chooseMention(actor)}
                      style={styles.person}
                    >
                      {actor.avatar ? (
                        <Image source={{ uri: actor.avatar }} style={styles.avatar} />
                      ) : (
                        <View style={[styles.avatar, styles.avatarPlaceholder]}>
                          <StoryIcon name="person" size={28} color="white" />
                        </View>
                      )}
                      <Text numberOfLines={1} style={styles.username}>
                        @{actor.username}
                      </Text>
                      <Text numberOfLines={1} style={styles.personName}>
                        {actor.name}
                      </Text>
                    </Pressable>
                  ))}
                </ScrollView>
              ) : (
                <Text style={styles.suggestionMessage}>
                  {!query
                    ? "Type a username"
                    : search.isFetching || query !== debounced
                      ? "Searching..."
                      : search.isError
                        ? errorMessage({ error: search.error })
                        : "No matching Instagram users"}
                </Text>
              )}
            </View>
          ) : null}
          {Platform.OS === "ios" ? (
            <CaptionAccessory caption={caption} onChange={update} onDone={finishEditing} />
          ) : (
            <View style={[styles.accessory, { top: toolbarTop }]}>
              <Tool
                label="Change text background"
                onPress={() =>
                  update({
                    ...caption,
                    background: (caption.background + 1) % captionBackgrounds.length,
                  })
                }
              >
                <Swatch color={captionBackgrounds[caption.background]!} />
              </Tool>
              <Tool
                label="Change font"
                onPress={() =>
                  update({ ...caption, font: (caption.font + 1) % captionFonts.length })
                }
              >
                <Text style={[styles.textIcon, { fontFamily: captionFonts[caption.font] }]}>A</Text>
              </Tool>
              <Tool
                label="Change text color"
                onPress={() =>
                  update({ ...caption, color: (caption.color + 1) % captionColors.length })
                }
              >
                <Swatch color={captionColors[caption.color]!} />
              </Tool>
              <View style={{ flex: 1 }} />
              <Tool label="Done editing text" icon="keyboard-hide" onPress={finishEditing} />
            </View>
          )}
        </>
      ) : null}
      {/* A separate, undimmed 9:16 canvas keeps editor controls and the keyboard out of exports. */}
      <View
        pointerEvents="none"
        accessibilityElementsHidden
        importantForAccessibility="no-hide-descendants"
        style={{ position: "absolute", left: -width * 2, top: 0, ...exportSize }}
      >
        <View ref={canvas} collapsable={false} style={{ ...exportSize, overflow: "hidden" }}>
          <Background index={background} />
          {image ? (
            <Image
              key={image}
              source={{ uri: image }}
              resizeMode="contain"
              style={StyleSheet.absoluteFill}
              onLoad={() => setLoadedImage(image)}
              onError={() => {
                setLoadedImage(undefined);
                Alert.alert(
                  "Image Selection Failed",
                  "This photo couldn't load. Choose another photo.",
                );
              }}
            />
          ) : null}
          {captions.map((item) => (
            <StoryCaption
              key={item.id}
              caption={item}
              width={exportSize.width}
              height={exportSize.height}
              textScale={exportText.scale}
              maxWidth={exportText.maxWidth}
            />
          ))}
        </View>
      </View>
    </View>
  );
}
const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: "black", overflow: "hidden" },
  empty: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    gap: 14,
    paddingHorizontal: 32,
  },
  placeholder: { fontSize: 17, fontWeight: "600", textAlign: "center", color: "white" },
  top: {
    zIndex: 4,
    position: "absolute",
    left: 16,
    right: 16,
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "flex-start",
  },
  tools: { gap: 12 },
  tool: {
    width: 44,
    height: 44,
    borderRadius: 22,
    backgroundColor: "#00000073",
    alignItems: "center",
    justifyContent: "center",
  },
  textIcon: { fontSize: 24, fontWeight: "700", color: "white", includeFontPadding: false },
  swatch: {
    width: 24,
    height: 24,
    borderRadius: 12,
    borderWidth: 1.5,
    borderColor: "#FFFFFFBF",
    overflow: "hidden",
  },
  postContainer: { position: "absolute", left: 0, right: 0, alignItems: "center", zIndex: 4 },
  post: {
    height: 44,
    paddingHorizontal: 22,
    borderRadius: 22,
    backgroundColor: "#00000073",
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
  },
  postText: { color: "white", fontSize: 15, fontWeight: "500" },
  trash: {
    position: "absolute",
    bottom: 54,
    width: 76,
    height: 76,
    borderRadius: 38,
    borderWidth: 2,
    alignItems: "center",
    justifyContent: "center",
    zIndex: 3,
  },
  accessory: {
    zIndex: 5,
    position: "absolute",
    left: 16,
    right: 16,
    height: 56,
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
  },
  suggestions: {
    zIndex: 5,
    position: "absolute",
    left: 18,
    right: 18,
    backgroundColor: "#000000C7",
    borderRadius: 18,
    borderWidth: 1,
    borderColor: "#FFFFFF24",
    overflow: "hidden",
    justifyContent: "center",
  },
  suggestionMessage: {
    fontSize: 13,
    color: "#FFFFFFB8",
    textAlign: "center",
    paddingHorizontal: 8,
  },
  suggestionContent: { paddingHorizontal: 8, alignItems: "center" },
  person: { width: 92, paddingHorizontal: 4, alignItems: "center", gap: 4 },
  avatar: { width: 48, height: 48, borderRadius: 24 },
  avatarPlaceholder: {
    backgroundColor: "#FFFFFF33",
    alignItems: "center",
    justifyContent: "center",
  },
  username: { fontSize: 12, fontWeight: "700", color: "white" },
  personName: { fontSize: 11, color: "#FFFFFFAD" },
});
