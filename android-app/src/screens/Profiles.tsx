import { useState, useEffect, useRef } from "react";
import {
  View,
  Image,
  Pressable,
  ScrollView,
  useWindowDimensions,
  ActivityIndicator,
  Platform,
} from "react-native";
import { useNavigation, useIsFocused } from "@react-navigation/native";
import type { NativeStackNavigationProp } from "@react-navigation/native-stack";
import { useQuery, useMutation, useInfiniteQuery } from "@tanstack/react-query";
import { Ionicons } from "@expo/vector-icons";
import { useVideoPlayer, VideoView } from "expo-video";
import type { Routes, ScreenProps } from "../app/navigation";
import {
  type Network,
  type Post,
  type Actor,
  type Profile,
  networks,
  networkNames,
  relativeTime,
  errorMessage,
} from "../app/models";
import {
  getProfile,
  searchProfiles,
  profileURL,
  queryClient,
  notificationDetail,
} from "../app/services";
import { xRelationship, xDevicePosts } from "../x/client";
import { instagramFollow, instagramPosts } from "../instagram/client";
import { usePreview } from "../app/preview";
import { Button, Busy, ErrorNotice, openURL } from "../components/ui";
import { SocialAvatar, networkImages, InlineIcon } from "../components/social";
import { NativeMenu, ToolbarButton } from "../components/native";
import { androidSmallText } from "../components/typography";
import { actorName, notificationActivity, profileCount, likeCount } from "../app/presentation";
import {
  FormScreen,
  FormInput,
  FormSection,
  FormRow,
  FormText,
  EmptyState,
  useFormColors,
} from "../components/forms";

function Badge({ network, size = 16 }: { network: Network; size?: number }) {
  return (
    <Image source={networkImages[network]} style={{ width: size, height: size, borderRadius: 3 }} />
  );
}
function PersonRow({
  actor,
  profile,
  onPress,
}: {
  actor: Actor;
  profile?: Profile;
  onPress: () => void;
}) {
  return (
    <FormRow
      actor={actor}
      title={profile ? actor.name || actor.username : actorName({ actor })}
      subtitle={profile ? `@${actor.username}` : undefined}
      verified={profile?.verified}
      onPress={onPress}
      link
    />
  );
}

export function SearchScreen() {
  const navigation = useNavigation<NativeStackNavigationProp<Routes>>(),
    [query, setQuery] = useState(""),
    [debounced, setDebounced] = useState(""),
    [enabled, setEnabled] = useState<Network[]>([...networks]),
    preview = usePreview();
  useEffect(() => {
    const timer = setTimeout(() => setDebounced(query.trim()), 450);
    return () => clearTimeout(timer);
  }, [query]);
  const result = useQuery({
    queryKey: ["search", debounced],
    queryFn: () => searchProfiles({ query: debounced }),
    enabled: debounced.length >= 2 && !preview.enabled,
  });
  const profiles =
    !preview.enabled && query.trim() === debounced && debounced.length >= 2
      ? (result.data?.profiles.filter((p) => enabled.includes(p.network)) ?? [])
      : [];
  const errors = Object.entries(preview.enabled ? {} : (result.data?.errors ?? {})).filter(
    ([network]) => enabled.includes(network as Network),
  );
  const description =
    preview.enabled && query.trim().length > 0
      ? "Search is available with your connected accounts after unloading preview content."
      : result.error
        ? errorMessage({ error: result.error })
        : errors.length
          ? errors
              .map(([network, error]) => `${networkNames[network as Network]}: ${error}`)
              .join("\n")
          : debounced.length >= 2
            ? "No profiles found on the selected networks."
            : "Enter a handle to search connected networks.";
  return (
    <FormScreen
      title="Search"
      grouped={false}
      bottom={
        <FormInput
          label="Search"
          placeholder="Search profiles"
          value={query}
          onChange={setQuery}
          search
        />
      }
      trailing={
        <NativeMenu
          label="Filter networks"
          actions={networks.map((network) => ({
            id: network,
            title: networkNames[network],
            state: enabled.includes(network) ? "on" : "off",
          }))}
          onAction={(id) =>
            setEnabled((current) =>
              current.includes(id as Network)
                ? current.filter((n) => n !== id)
                : [...current, id as Network],
            )
          }
        />
      }
    >
      {profiles.length ? (
        <FormSection title="Profiles">
          {profiles.map((profile) => (
            <PersonRow
              key={`${profile.network}:${profile.id}`}
              actor={profile}
              profile={profile}
              onPress={() =>
                navigation.navigate("Profile", { actor: profile, initialProfile: profile })
              }
            />
          ))}
        </FormSection>
      ) : (
        <EmptyState
          title={debounced.length >= 2 ? "No Results" : "Search Profiles"}
          description={description}
          loading={!preview.enabled && (result.isFetching || query.trim() !== debounced)}
          icon={debounced.length >= 2 ? "person-circle-outline" : "search"}
        />
      )}
      {profiles.length && errors.length ? (
        <FormSection>
          {errors.map(([network, error]) => (
            <FormRow key={network}>
              <ErrorNotice error={`${networkNames[network as Network]}: ${error}`} />
            </FormRow>
          ))}
        </FormSection>
      ) : null}
    </FormScreen>
  );
}
function PostImages({ images }: { images: string[] }) {
  const [width, setWidth] = useState(0),
    [ratios, setRatios] = useState<Record<string, number>>({});
  return (
    <View onLayout={(event) => setWidth(event.nativeEvent.layout.width)}>
      {width > 0 ? (
        <ScrollView horizontal pagingEnabled showsHorizontalScrollIndicator={false}>
          {images.map((uri) => (
            <Image
              key={uri}
              source={{ uri }}
              onLoad={({ nativeEvent }) => {
                const { width: w, height: h } = nativeEvent.source;
                if (w && h) setRatios((r) => ({ ...r, [uri]: w / h }));
              }}
              style={{ width, aspectRatio: ratios[uri] ?? 1, borderRadius: 10 }}
              resizeMode="contain"
              accessibilityLabel="Post image"
            />
          ))}
        </ScrollView>
      ) : null}
    </View>
  );
}
export function PostCard({
  post,
  network,
  onAuthor,
  onOpen,
}: {
  post: Post;
  network: Network;
  onAuthor?: () => void;
  onOpen?: () => void;
}) {
  const c = useFormColors();
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel="Open post"
      onPress={onOpen ?? (() => void openURL({ url: post.url }))}
      style={{ padding: 16, paddingVertical: 20, gap: 12 }}
    >
      <View style={{ flexDirection: "row", alignItems: "flex-start", gap: 10 }}>
        <Pressable accessibilityLabel="Open author profile" onPress={onAuthor} disabled={!onAuthor}>
          {post.author ? (
            <SocialAvatar actor={post.author} size={36} />
          ) : (
            <View
              style={{
                width: 36,
                height: 36,
                borderRadius: 18,
                backgroundColor: c.fill,
                alignItems: "center",
                justifyContent: "center",
              }}
            >
              <Badge network={network} />
            </View>
          )}
        </Pressable>
        <View style={{ flex: 1, gap: 2 }}>
          <FormText
            style={{ fontSize: 15, lineHeight: Platform.OS === "ios" ? 18 : 20, fontWeight: "600" }}
          >
            {post.author?.name || post.author?.username || networkNames[network]}
          </FormText>
          <FormText
            secondary
            style={{
              fontSize: 12,
              lineHeight: Platform.OS === "ios" ? 14 : 16,
              ...androidSmallText,
            }}
          >
            {post.author ? `@${post.author.username}` : networkNames[network]}
            {post.timestamp ? `  •  ${relativeTime({ timestamp: post.timestamp })}` : ""}
          </FormText>
        </View>
        <InlineIcon name="open" size={Platform.OS === "ios" ? 12 : 14} color={c.secondary} />
      </View>
      {post.text ? <FormText>{post.text}</FormText> : null}
      {post.images.length ? <PostImages images={post.images} /> : null}
      {post.likes !== undefined ? (
        <View style={{ flexDirection: "row", gap: 2, alignItems: "center" }}>
          <InlineIcon name="heart" size={Platform.OS === "ios" ? 12 : 13} color={c.secondary} />
          <FormText secondary style={{ fontSize: 12, lineHeight: 16, ...androidSmallText }}>
            {likeCount({ value: post.likes })}
          </FormText>
        </View>
      ) : null}
    </Pressable>
  );
}
export function ProfileScreen({ route, navigation }: ScreenProps<"Profile">) {
  const { actor, preview, initialProfile } = route.params,
    c = useFormColors(),
    queryKey = ["profile", actor.network, actor.id];
  const profile = useQuery({
    queryKey,
    queryFn: () => getProfile({ actor }),
    enabled: !preview,
    initialData: preview ? undefined : initialProfile,
    initialDataUpdatedAt: 0,
  });
  const p: Profile = preview
    ? { ...actor, bio: "Sample profile for demonstration.", followers: 128, following: 64 }
    : (profile.data ?? { ...actor, bio: "" });
  const change = useMutation({
    mutationFn: async ({ follow, notify }: { follow?: boolean; notify?: boolean }) => {
      if (actor.network === "x") await xRelationship({ userId: p.id, follow, notify });
      else if (actor.network === "instagram" && follow !== undefined)
        await instagramFollow({ id: p.id, following: follow });
    },
    onSuccess: (_, input) =>
      queryClient.setQueryData(queryKey, {
        ...p,
        ...(input.follow === undefined ? {} : { isFollowing: input.follow }),
        ...(input.notify === undefined ? {} : { notifyPosts: input.notify }),
      }),
  });
  const posts = useInfiniteQuery({
    queryKey: ["profilePosts", actor.network, p.id],
    queryFn: ({ pageParam }) => instagramPosts({ username: p.username, cursor: pageParam }),
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (last) => last.nextCursor,
    enabled: actor.network === "instagram" && !!profile.data && !preview,
  });
  const device = useQuery({
    queryKey: ["devicePosts", actor.id],
    queryFn: () => xDevicePosts({ actorId: actor.id }),
    enabled: actor.network === "x" && !preview,
  });
  const nextCursor = posts.data?.pages.at(-1)?.nextCursor,
    requested = useRef(new Set<string>());
  const loadMore = () => {
    if (nextCursor && !posts.isFetching && !posts.isError && !requested.current.has(nextCursor)) {
      requested.current.add(nextCursor);
      void posts.fetchNextPage();
    }
  };
  const postItems = [
    ...new Map(
      (posts.data?.pages.flatMap((page) => page.posts) ?? []).map((post) => [post.id, post]),
    ).values(),
  ];
  const relation =
    !preview &&
    (actor.network === "x" || actor.network === "instagram") &&
    p.isFollowing !== undefined;
  return (
    <FormScreen
      title="Profile"
      trailing={profile.isFetching && profile.data ? <ActivityIndicator /> : undefined}
      onScroll={({ nativeEvent: e }) => {
        if (e.contentOffset.y + e.layoutMeasurement.height >= e.contentSize.height - 150)
          loadMore();
      }}
    >
      {!preview && !profile.data && profile.isPending ? (
        <EmptyState title="" description="" loading />
      ) : !preview && !profile.data && profile.error ? (
        <EmptyState
          title="Couldn't Load Profile"
          description={errorMessage({ error: profile.error })}
          icon="warning-outline"
        />
      ) : (
        <>
          <FormSection>
            <View
              style={{ padding: Platform.OS === "ios" ? 24 : 22, alignItems: "center", gap: 12 }}
            >
              <SocialAvatar actor={p} size={80} border={false} />
              <View style={{ alignItems: "center", gap: 4 }}>
                <View style={{ flexDirection: "row", gap: 4, alignItems: "center" }}>
                  <FormText
                    style={{
                      fontSize: 22,
                      lineHeight: 28,
                      fontWeight: "700",
                      textAlign: "center",
                      flexShrink: 1,
                    }}
                  >
                    {p.name || p.username}
                  </FormText>
                  {p.verified ? (
                    <InlineIcon
                      name="verified"
                      size={Platform.OS === "ios" ? 16 : 19}
                      color={c.blue}
                    />
                  ) : null}
                </View>
                <FormText secondary style={{ fontSize: 15, lineHeight: 20 }}>
                  @{p.username}
                </FormText>
                {p.isFollowing && p.followsYou ? (
                  <View
                    style={{
                      borderRadius: 14,
                      backgroundColor: c.secondary + "1a",
                      paddingHorizontal: 8,
                      paddingVertical: 2,
                    }}
                  >
                    <FormText
                      secondary
                      style={{
                        fontSize: 12,
                        lineHeight: 16,
                        ...androidSmallText,
                        fontWeight: "500",
                      }}
                    >
                      You follow each other
                    </FormText>
                  </View>
                ) : null}
              </View>
              {relation || (!preview && actor.network === "x") ? (
                <View style={{ flexDirection: "row", gap: 8, paddingTop: 4 }}>
                  {relation ? (
                    <Button
                      title={p.isFollowing ? "Following" : "Follow"}
                      disabled={change.isPending}
                      onPress={() => change.mutate({ follow: !p.isFollowing })}
                    />
                  ) : null}
                  {actor.network === "x" ? (
                    <ToolbarButton
                      label={
                        p.notifyPosts ? "Turn off post notifications" : "Turn on post notifications"
                      }
                      icon={p.notifyPosts ? "notifications" : "notifications-outline"}
                      disabled={change.isPending}
                      onPress={() => change.mutate({ notify: !p.notifyPosts })}
                    />
                  ) : null}
                </View>
              ) : null}
            </View>
          </FormSection>
          {change.error ? (
            <FormSection>
              <FormRow>
                <ErrorNotice error={change.error} />
              </FormRow>
            </FormSection>
          ) : null}
          {p.bio ? (
            <FormSection title="Bio">
              <FormRow>
                <FormText>{p.bio}</FormText>
              </FormRow>
            </FormSection>
          ) : null}
          {[p.followers, p.following, p.posts].some((n) => n !== undefined) ? (
            <FormSection>
              {p.followers !== undefined ? (
                <FormRow title="Followers" value={profileCount({ value: p.followers })} />
              ) : null}
              {p.following !== undefined ? (
                <FormRow title="Following" value={profileCount({ value: p.following })} />
              ) : null}
              {p.posts !== undefined ? (
                <FormRow
                  title={actor.network === "github" ? "Repositories" : "Posts"}
                  value={profileCount({ value: p.posts })}
                />
              ) : null}
            </FormSection>
          ) : null}
          {p.location ? (
            <FormSection>
              <FormRow title="Location" value={p.location} />
            </FormSection>
          ) : null}
          {p.joinedAt ? (
            <FormSection>
              <FormRow
                title="Joined"
                value={new Date(p.joinedAt).toLocaleDateString(undefined, {
                  day: "numeric",
                  month: "short",
                  year: "numeric",
                })}
              />
            </FormSection>
          ) : null}
          {p.website ? (
            <FormSection>
              <FormRow
                plain
                title={p.website.replace(/^https?:\/\/(www\.)?/, "").replace(/\/$/, "")}
                onPress={() => void openURL({ url: p.website! })}
                external
              />
            </FormSection>
          ) : null}
          <FormSection>
            <FormRow
              title={`View on ${networkNames[actor.network]}`}
              onPress={() => void openURL({ url: profileURL({ actor }) })}
              external
            />
          </FormSection>
          {!preview && profile.data && profile.error ? (
            <FormSection>
              <FormRow>
                <ErrorNotice error={profile.error} />
              </FormRow>
              <FormRow title="Retry profile" onPress={() => void profile.refetch()} />
            </FormSection>
          ) : null}
          {postItems.length ? (
            <FormSection separators={false}>
              <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 1 }}>
                {postItems.map((post) => (
                  <Pressable
                    key={post.id}
                    accessibilityRole="button"
                    accessibilityLabel={post.text || "Instagram post"}
                    onPress={() => navigation.navigate("Post", { post, network: "instagram" })}
                    style={{ width: "33.1%", aspectRatio: 1, backgroundColor: c.fill }}
                  >
                    {post.images[0] ? (
                      <Image
                        source={{ uri: post.images[0] }}
                        style={{ width: "100%", height: "100%" }}
                      />
                    ) : null}
                    {post.media?.some((m) => m.video) || post.images.length > 1 ? (
                      <Ionicons
                        name={post.media?.some((m) => m.video) ? "play" : "copy"}
                        color="white"
                        size={14}
                        style={{ position: "absolute", right: 7, top: 7 }}
                      />
                    ) : null}
                  </Pressable>
                ))}
              </View>
              {posts.isFetching ? (
                <Busy />
              ) : posts.hasNextPage ? (
                <FormRow
                  title={posts.isError ? "Retry" : "Load more posts"}
                  onPress={() => void posts.fetchNextPage()}
                  centered
                />
              ) : null}
            </FormSection>
          ) : posts.isFetching ? (
            <Busy />
          ) : null}
          {posts.error ? (
            <FormSection title="Posts">
              <FormRow>
                <ErrorNotice error={posts.error} />
              </FormRow>
            </FormSection>
          ) : null}
          {device.data?.length ? (
            <FormSection title="Post notifications">
              {device.data.map((post) => (
                <PostCard
                  key={post.id}
                  post={post}
                  network="x"
                  onAuthor={() => navigation.push("Profile", { actor: post.author! })}
                />
              ))}
            </FormSection>
          ) : null}
          {device.error ? <ErrorNotice error={device.error} /> : null}
        </>
      )}
    </FormScreen>
  );
}
function notificationTitle({ item }: { item: Routes["Notification"]["item"] }) {
  return item.category === "mentions"
    ? "Mention"
    : item.category === "replies"
      ? "Reply"
      : item.category === "follows"
        ? "Follow"
        : item.category === "messages"
          ? "Message"
          : item.category === "posts"
            ? "Tweet"
            : /starred/i.test(item.text)
              ? "Starred"
              : /retweet|repost/i.test(item.text)
                ? "Retweet"
                : "Like";
}
export function NotificationScreen({ route, navigation }: ScreenProps<"Notification">) {
  const { item, preview } = route.params,
    c = useFormColors(),
    detail = useQuery({
      queryKey: ["notification", item.id],
      queryFn: () => notificationDetail({ item }),
      enabled: !preview && item.category !== "messages",
    }),
    post = detail.data?.post ?? item.post,
    parent = detail.data?.parentPost ?? item.parentPost;
  const open = () => {
    const url = item.url ?? post?.url;
    if (!url) return;
    if (item.network === "instagram" && item.category === "messages")
      navigation.navigate("Browser", { url, title: "Conversation" });
    else void openURL({ url });
  };
  const card = (p: Post) => (
    <PostCard
      post={p}
      network={item.network}
      onAuthor={
        p.author ? () => navigation.push("Profile", { actor: p.author!, preview }) : undefined
      }
    />
  );
  return (
    <FormScreen title={notificationTitle({ item })}>
      <FormSection>
        <FormRow title="Network" value={networkNames[item.network]} />
        <FormRow
          title="Activity"
          value={Platform.OS === "ios" ? item.text : notificationActivity({ item })}
          multiline={Platform.OS !== "ios" && notificationActivity({ item }).length > 30}
        />
      </FormSection>
      {post ? (
        <FormSection
          title={
            parent
              ? "Thread"
              : item.network === "github"
                ? "Repository"
                : item.category === "messages"
                  ? "Message"
                  : "Post"
          }
          separators={false}
        >
          {!preview && detail.isFetching && !parent ? (
            <View style={{ minHeight: 120, justifyContent: "center" }}>
              <Busy />
            </View>
          ) : parent ? (
            <>
              {card(parent)}
              <View
                style={{
                  height: 18,
                  width: 2,
                  backgroundColor: c.secondary + "48",
                  marginLeft: 33,
                  marginVertical: 2,
                }}
              />
              {card(post)}
            </>
          ) : item.category === "messages" ? (
            <View
              style={{
                flexDirection: "row",
                alignItems: "flex-end",
                gap: 10,
                padding: 16,
                paddingVertical: 20,
              }}
            >
              <SocialAvatar actor={item.actors[0]!} size={32} />
              <View style={{ flex: 1, gap: 4, paddingRight: 32 }}>
                <FormText secondary style={{ fontSize: 12, lineHeight: 16, ...androidSmallText }}>
                  {actorName({ actor: item.actors[0]! })} •{" "}
                  {relativeTime({ timestamp: item.timestamp })}
                </FormText>
                <Pressable
                  accessibilityRole="button"
                  accessibilityLabel="Open conversation"
                  onPress={open}
                  style={{
                    alignSelf: "flex-start",
                    borderRadius: 18,
                    backgroundColor: c.secondary + "1f",
                    paddingHorizontal: 12,
                    paddingVertical: 9,
                    gap: 8,
                  }}
                >
                  {post.text &&
                  !(
                    post.images.length && /^(sent a reel|sent a post|sent media)/i.test(post.text)
                  ) ? (
                    <FormText>{post.text}</FormText>
                  ) : null}
                  {post.images[0] ? (
                    <Image
                      source={{ uri: post.images[0] }}
                      style={{ width: 180, height: 180, borderRadius: 14 }}
                    />
                  ) : null}
                </Pressable>
              </View>
            </View>
          ) : item.network === "github" ? (
            <View style={{ padding: 16, gap: 12 }}>
              {post.images.length ? <PostImages images={post.images.slice(0, 1)} /> : null}
              <FormText style={{ fontSize: 15, fontWeight: "600" }}>
                {new URL(post.url).pathname.replace(/^\//, "")}
              </FormText>
              <FormText>{post.text}</FormText>
              <FormRow title="View on GitHub" onPress={open} external />
            </View>
          ) : item.relatedPosts.length ? (
            item.relatedPosts.map((p) => <View key={p.id}>{card(p)}</View>)
          ) : (
            card(post)
          )}
        </FormSection>
      ) : (
        <FormSection title="Content">
          <FormRow>
            <FormText>{item.text}</FormText>
          </FormRow>
        </FormSection>
      )}
      {detail.error ? (
        <FormSection>
          <FormRow>
            <ErrorNotice error={detail.error} />
          </FormRow>
        </FormSection>
      ) : null}
      <FormSection title="People">
        {item.actors.map((actor) => (
          <PersonRow
            key={actor.id}
            actor={actor}
            onPress={() => navigation.push("Profile", { actor, preview })}
          />
        ))}
      </FormSection>
    </FormScreen>
  );
}
function PostVideo({ uri, size, active }: { uri: string; size: number; active: boolean }) {
  const focused = useIsFocused(),
    player = useVideoPlayer(uri);
  useEffect(() => {
    if (focused && active) player.play();
    else player.pause();
  }, [focused, player, active]);
  return (
    <VideoView
      player={player}
      nativeControls
      contentFit="contain"
      style={{ width: size, height: size }}
    />
  );
}
export function PostScreen({ route }: ScreenProps<"Post">) {
  const { post, network } = route.params,
    { width } = useWindowDimensions(),
    [activeMedia, setActiveMedia] = useState(0);
  const media = post.media?.length
    ? post.media
    : post.images.map((image) => ({ image, video: undefined }));
  return (
    <FormScreen title="Post" inline grouped={false}>
      <ScrollView
        horizontal
        pagingEnabled
        showsHorizontalScrollIndicator={false}
        onMomentumScrollEnd={({ nativeEvent }) =>
          setActiveMedia(Math.round(nativeEvent.contentOffset.x / width))
        }
      >
        {media.map((m, index) => (
          <View key={index} style={{ width, height: width, backgroundColor: "black" }}>
            {m.video ? (
              <PostVideo uri={m.video} size={width} active={index === activeMedia} />
            ) : m.image ? (
              <Image
                source={{ uri: m.image }}
                resizeMode="contain"
                style={{ width, height: width }}
              />
            ) : null}
          </View>
        ))}
      </ScrollView>
      <View style={{ padding: 16, gap: 10 }}>
        <FormText>{post.text}</FormText>
        <FormRow
          title={`View on ${networkNames[network]}`}
          onPress={() => void openURL({ url: post.url })}
          external
        />
      </View>
    </FormScreen>
  );
}
