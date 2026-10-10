import { useEffect, useLayoutEffect, useRef } from "react";
import { AppState, FlatList, Platform, View } from "react-native";
import { useNavigation } from "@react-navigation/native";
import type { NativeStackNavigationProp } from "@react-navigation/native-stack";
import { useMutation, useQuery } from "@tanstack/react-query";
import { SafeAreaView } from "react-native-safe-area-context";
import type { Routes } from "../app/navigation";
import { loadAccounts, loadFeed } from "../app/storage";
import { initialize, refreshFeed } from "../app/services";
import { usePreview, previewData } from "../app/preview";
import { Label, Button, Busy, ErrorNotice } from "../components/ui";
import { NotificationRow, NotificationSeparator, useSocialColors } from "../components/social";
import { ToolbarButton } from "../components/native";
import { StoryBar } from "../components/StoryBar";
export function FeedScreen() {
  const navigation = useNavigation<NativeStackNavigationProp<Routes>>(),
    c = useSocialColors(),
    preview = usePreview(),
    sample = useRef(previewData()).current;
  const startup = useQuery({ queryKey: ["startup"], queryFn: initialize, staleTime: Infinity }),
    accounts = useQuery({ queryKey: ["accounts"], queryFn: loadAccounts }),
    feed = useQuery({ queryKey: ["feed"], queryFn: loadFeed }),
    refresh = useMutation({ mutationFn: refreshFeed });
  const last = useRef(0),
    doRefresh = useRef(() => {});
  doRefresh.current = () => {
    if (preview.enabled || Date.now() - last.current < 15000) return;
    last.current = Date.now();
    refresh.mutate();
  };
  useEffect(() => {
    if (startup.isSuccess) doRefresh.current();
  }, [startup.isSuccess]);
  useEffect(() => {
    const sub = AppState.addEventListener("change", (state) => {
      if (state === "active") doRefresh.current();
    });
    return () => sub.remove();
  }, []);
  const currentAccounts = preview.enabled ? sample.accounts : (accounts.data ?? []),
    data = preview.enabled ? sample : feed.data,
    notifications = data?.notifications ?? [];
  const errors = {
    ...Object.fromEntries(
      Object.entries(startup.data ?? {}).filter(
        ([n]) => !accounts.data?.some((a) => a.network === n),
      ),
    ),
    ...refresh.data,
  };
  const openSettings = () =>
    navigation.navigate("Settings", { issues: preview.enabled ? {} : errors });
  useLayoutEffect(() => {
    navigation.setOptions({
      title: "Social",
      headerLargeTitle: Platform.OS === "ios",
      headerRight: () => (
        <View style={{ flexDirection: "row", gap: Platform.OS === "ios" ? 10 : 0 }}>
          <ToolbarButton
            label="Search"
            icon="search-outline"
            onPress={() => navigation.navigate("Search")}
          />
          <ToolbarButton
            label={
              !preview.enabled && Object.keys(errors).length
                ? "Settings, connection needs attention"
                : "Settings"
            }
            badge={!preview.enabled && Object.keys(errors).length > 0}
            icon="settings-outline"
            onPress={openSettings}
          />
        </View>
      ),
    });
  });
  return (
    <SafeAreaView edges={["left", "right"]} style={{ flex: 1, backgroundColor: c.background }}>
      <FlatList
        contentInsetAdjustmentBehavior="automatic"
        removeClippedSubviews={false}
        data={notifications}
        keyExtractor={(item) => item.id}
        contentContainerStyle={{ paddingBottom: 32 }}
        ItemSeparatorComponent={NotificationSeparator}
        refreshing={refresh.isPending}
        onRefresh={() => {
          if (!preview.enabled) refresh.mutate();
        }}
        ListHeaderComponent={
          <>
            <StoryBar
              reels={data?.stories ?? []}
              account={
                preview.enabled ? undefined : currentAccounts.find((a) => a.network === "instagram")
              }
              preview={preview.enabled}
              onCompose={() => navigation.navigate("Composer")}
              onOpen={(reels, index) =>
                navigation.navigate("Stories", { reels, index, preview: preview.enabled })
              }
            />
            <ErrorNotice error={feed.error || accounts.error || startup.error || refresh.error} />
          </>
        }
        renderItem={({ item }) => (
          <NotificationRow
            item={item}
            onPress={() => navigation.navigate("Notification", { item, preview: preview.enabled })}
          />
        )}
        ListEmptyComponent={
          startup.isPending || feed.isPending ? (
            <Busy />
          ) : (
            <View style={{ padding: 24, paddingTop: 120, alignItems: "center", gap: 10 }}>
              <Label>No Notifications</Label>
              <Label muted>
                {currentAccounts.length
                  ? "You're caught up."
                  : "Connect social accounts to get started."}
              </Label>
              <Button title="Open Settings" onPress={openSettings} />
            </View>
          )
        }
      />
    </SafeAreaView>
  );
}
