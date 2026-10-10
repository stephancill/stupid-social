import { useState, useRef, useEffect, useMemo } from "react";
import { Alert, AppState, View, Text } from "react-native";
import { useIsFocused } from "@react-navigation/native";
import { useMutation, useQuery } from "@tanstack/react-query";
import { WebView } from "react-native-webview";
import { z } from "zod";
import { type ScreenProps } from "../app/navigation";
import {
  networkNames,
  categories,
  categoryLabels,
  socialError,
  type Network,
  type Category,
} from "../app/models";
import {
  loadAccounts,
  removeAccount,
  loadPreferences,
  savePreferences,
  saveCredentials,
  credentials,
  generation,
  invalidateSession,
  clearCache,
  type Credentials,
} from "../app/storage";
import { queryClient, connect, refreshFeed } from "../app/services";
import { loginBluesky } from "../providers/bluesky";
import { usePreview } from "../app/preview";
import { Label, Button, Busy, ErrorNotice, openURL } from "../components/ui";
import { FormScreen, FormInput, FormSection, FormRow, FormToggle } from "../components/forms";
import { bridge, EarlyWebView } from "../bridge";
import { loginURLs, cookieURLs, parseCookies } from "../storage";
import { captureScript } from "../capture";
import { androidSmallText } from "../components/typography";
import { createLoginCookieDetector } from "../app/loginCookies";

const connectionOrder: Network[] = ["x", "farcaster", "instagram", "spotify", "bluesky", "github"];
export function SettingsScreen({ route, navigation }: ScreenProps<"Settings">) {
  const accounts = useQuery({ queryKey: ["accounts"], queryFn: loadAccounts }),
    preview = usePreview(),
    taps = useRef({ count: 0, at: 0 }),
    [developer, setDeveloper] = useState(false);
  const clear = useMutation({
    mutationFn: clearCache,
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["feed"] }),
  });
  return (
    <FormScreen title="Settings">
      <FormSection title="Connections">
        {connectionOrder.map((network) => {
          const account = accounts.data?.find((a) => a.network === network),
            issue = route.params?.issues?.[network];
          return (
            <FormRow
              key={network}
              title={networkNames[network]}
              value={
                issue ? "Needs attention" : account ? `@${account.username}` : "Not configured"
              }
              invalid={!!issue}
              label={`${networkNames[network]} account`}
              link
              disabled={preview.enabled}
              onPress={() => navigation.navigate("Account", { network, issue })}
            />
          );
        })}
      </FormSection>
      {developer ? (
        <FormSection
          title="Demo Data"
          footer="Preview content uses sample notifications and stories. Unload it to return to your connected accounts."
        >
          <FormRow title="Load preview content" onPress={() => preview.setEnabled(true)} />
          <FormRow
            title="Unload preview content"
            destructive
            onPress={() => preview.setEnabled(false)}
          />
        </FormSection>
      ) : null}
      <FormSection
        title="About"
        onTitlePress={() => {
          const now = Date.now();
          taps.current = {
            count: now - taps.current.at < 1000 ? taps.current.count + 1 : 1,
            at: now,
          };
          if (taps.current.count >= 4) {
            taps.current.count = 0;
            if (developer) preview.setEnabled(false);
            setDeveloper(!developer);
          }
        }}
      >
        <FormRow
          title="stupidtech.net"
          plain
          onPress={() => void openURL({ url: "https://stupidtech.net" })}
          external
        />
        <FormRow
          title="GitHub"
          plain
          onPress={() => void openURL({ url: "https://github.com/stephancill/stupid-social" })}
          external
        />
      </FormSection>
      {developer ? (
        <FormSection title="Storage">
          <FormRow
            title="Clear notification cache"
            destructive
            disabled={preview.enabled || clear.isPending}
            onPress={() =>
              Alert.alert("Clear cached notifications?", "Your accounts will stay connected.", [
                { text: "Cancel", style: "cancel" },
                { text: "Clear", onPress: () => clear.mutate() },
              ])
            }
          />
          {clear.error ? (
            <FormRow>
              <ErrorNotice error={clear.error} />
            </FormRow>
          ) : null}
        </FormSection>
      ) : null}
    </FormScreen>
  );
}
const notificationOptions: Partial<Record<Network, { value: Category; title: string }[]>> = {
  x: [
    { value: "mentions", title: "Mentions" },
    { value: "replies", title: "Replies" },
    { value: "reactions", title: "Reactions" },
    { value: "posts", title: "Tweets" },
    { value: "follows", title: "Follows" },
  ],
  farcaster: [
    { value: "mentions", title: "Mentions" },
    { value: "replies", title: "Replies" },
    { value: "reactions", title: "Reactions" },
    { value: "follows", title: "Follows" },
  ],
  instagram: [
    { value: "follows", title: "Follows" },
    { value: "replies", title: "Comments" },
    { value: "reactions", title: "Likes" },
    { value: "posts", title: "Story Highlights" },
  ],
};
export function AccountScreen({ route, navigation }: ScreenProps<"Account">) {
  const { network, issue } = route.params,
    [handle, setHandle] = useState("");
  const accounts = useQuery({ queryKey: ["accounts"], queryFn: loadAccounts }),
    account = accounts.data?.find((a) => a.network === network),
    prefs = useQuery({
      queryKey: ["preferences", network],
      queryFn: () => loadPreferences({ network }),
    });
  const login = useMutation({
    mutationFn: async () => {
      if (network === "bluesky") {
        await loginBluesky({ handle });
        await connect({ network });
      } else {
        const value = z.string().trim().min(1).parse(handle.replace(/^@/, ""));
        await saveCredentials({ network, value: { username: value } });
        await connect({ network });
      }
      await refreshFeed();
    },
    onSuccess: () => queryClient.invalidateQueries(),
  });
  const update = useMutation({
    mutationFn: savePreferences,
    onSuccess: () => queryClient.invalidateQueries(),
  });
  const disconnect = useMutation({
    mutationFn: async () => {
      await removeAccount({ network });
      if (network in cookieURLs) {
        const provider = network as keyof typeof cookieURLs,
          header = await bridge.cookies(cookieURLs[provider]),
          domain = {
            x: "x.com",
            instagram: "instagram.com",
            github: "github.com",
            spotify: "spotify.com",
          }[provider];
        for (const key of Object.keys(parseCookies({ header }))) {
          await bridge.seedCookie(cookieURLs[provider], `${key}=; Max-Age=0; Path=/; Secure`);
          if (!key.startsWith("__Host-"))
            await bridge.seedCookie(
              cookieURLs[provider],
              `${key}=; Max-Age=0; Path=/; Domain=.${domain}; Secure`,
            );
        }
      }
    },
    onSuccess: () => queryClient.invalidateQueries(),
  });
  const toggle = ({ value, title }: { value: Category; title: string }) => (
    <FormToggle
      key={value}
      title={title}
      value={prefs.data!.categories.includes(value)}
      disabled={update.isPending}
      onChange={(enabled) =>
        update.mutate({
          network,
          value: {
            ...prefs.data!,
            categories: enabled
              ? [...prefs.data!.categories, value]
              : prefs.data!.categories.filter((category) => category !== value),
          },
        })
      }
    />
  );
  const field = (
    <FormInput
      label={`${networkNames[network]} handle`}
      placeholder={network === "bluesky" ? "Handle or email" : "Username"}
      value={handle}
      onChange={setHandle}
    />
  );
  const needsLogin = !account || !!issue;
  return (
    <FormScreen title={networkNames[network]}>
      {needsLogin && network === "bluesky" ? (
        <FormSection title="Login">
          {field}
          <FormRow
            centered
            title={login.isPending ? "Connecting…" : "Log in to Bluesky"}
            disabled={login.isPending || !handle.trim()}
            onPress={() => login.mutate()}
          />
        </FormSection>
      ) : needsLogin && network !== "farcaster" ? (
        <FormSection>
          <FormRow
            title={
              account ? `Reconnect ${networkNames[network]}` : `Log in to ${networkNames[network]}`
            }
            disabled={login.isPending}
            onPress={() =>
              navigation.navigate("Login", {
                network: network as "x" | "instagram" | "github" | "spotify",
              })
            }
          />
        </FormSection>
      ) : null}
      <FormSection>
        {!account && network === "farcaster" ? field : null}
        <FormRow
          title="Connection"
          value={account ? `@${account.username}` : issue ? "Needs attention" : "Not configured"}
        />
      </FormSection>
      {!account && network === "farcaster" ? (
        <FormSection>
          <FormRow
            title={login.isPending ? "Connecting…" : "Save Farcaster Account"}
            disabled={login.isPending || !handle.trim()}
            onPress={() => login.mutate()}
          />
        </FormSection>
      ) : null}
      {account && prefs.data ? (
        <>
          {network === "instagram" ? (
            <>
              <FormSection title="Content">
                <FormToggle
                  title="Stories"
                  value={prefs.data.storiesEnabled}
                  disabled={update.isPending}
                  onChange={(storiesEnabled) =>
                    update.mutate({ network, value: { ...prefs.data!, storiesEnabled } })
                  }
                />
              </FormSection>
              <FormSection title="Messaging">
                {toggle({ value: "messages", title: "Direct Messages" })}
                <FormToggle
                  title="Posts and Reels"
                  value={prefs.data.includeMediaShares}
                  disabled={update.isPending || !prefs.data.categories.includes("messages")}
                  onChange={(includeMediaShares) =>
                    update.mutate({ network, value: { ...prefs.data!, includeMediaShares } })
                  }
                />
              </FormSection>
            </>
          ) : null}
          {network !== "spotify" ? (
            <FormSection title={network === "x" ? "Notifications" : "Notification Types"}>
              {(
                notificationOptions[network] ??
                categories.map((value) => ({ value, title: categoryLabels[value] }))
              ).map(toggle)}
            </FormSection>
          ) : null}
          <FormSection>
            <FormRow
              title="Disconnect"
              destructive
              disabled={disconnect.isPending}
              onPress={() =>
                Alert.alert(
                  `Disconnect ${networkNames[network]}?`,
                  "This removes the saved session and its cached activity from this device.",
                  [
                    { text: "Cancel", style: "cancel" },
                    {
                      text: "Disconnect",
                      style: "destructive",
                      onPress: () => disconnect.mutate(),
                    },
                  ],
                )
              }
            />
          </FormSection>
        </>
      ) : null}
      {issue || login.error || disconnect.error || update.error ? (
        <FormSection>
          <FormRow>
            <ErrorNotice error={login.error || disconnect.error || update.error || issue} />
          </FormRow>
        </FormSection>
      ) : null}
    </FormScreen>
  );
}
export function LoginScreen({ route, navigation }: ScreenProps<"Login">) {
  const { network } = route.params,
    focused = useIsFocused(),
    [page, setPage] = useState(loginURLs[network]),
    [cookieError, setCookieError] = useState<unknown>(),
    token = useRef<{ bearerToken?: string; clientToken?: string }>({}),
    done = useRef(false),
    mounted = useRef(false),
    attempt = useRef<{ generation: number } | null>(null),
    detector = useRef<ReturnType<typeof createLoginCookieDetector> | null>(null);
  const config = useMemo(
    () => ({ url: loginURLs[network], script: captureScript({ native: true }) }),
    [network],
  );
  useEffect(() => {
    mounted.current = focused;
    return () => {
      mounted.current = false;
      const pending = attempt.current;
      if (!done.current && pending && generation({ network }) === pending.generation) {
        invalidateSession({ network });
        pending.generation = generation({ network });
      }
    };
  }, [network, focused]);
  const capture = useMutation({
    gcTime: 0,
    mutationFn: async (selected: Credentials) => {
      setCookieError(undefined);
      const previous = await credentials({ network });
      if (!mounted.current || done.current)
        throw socialError({ message: "Sign-in was cancelled." });
      invalidateSession({ network });
      const pending = { generation: generation({ network }) };
      attempt.current = pending;
      try {
        await saveCredentials({
          network,
          value: network === "spotify" ? { ...selected, ...token.current } : selected,
          expectedGeneration: pending.generation,
        });
        if (!mounted.current || generation({ network }) !== pending.generation)
          throw socialError({ message: "Sign-in was cancelled." });
        const connection = connect({ network });
        pending.generation = generation({ network });
        await connection;
      } catch (error) {
        await saveCredentials({ network, value: previous, expectedGeneration: pending.generation });
        throw error;
      } finally {
        if (attempt.current === pending) attempt.current = null;
      }
    },
    onSuccess: () => {
      if (!mounted.current) return;
      done.current = true;
      navigation.popTo("Account", { network });
      void refreshFeed().then(
        () => queryClient.invalidateQueries(),
        () => queryClient.invalidateQueries(),
      );
    },
  });
  const { mutateAsync } = capture;
  useEffect(() => {
    if (!focused) return;
    const watcher = createLoginCookieDetector({
      network,
      readCookies: () => bridge.cookies(cookieURLs[network]),
      connect: mutateAsync,
      isActive: () => mounted.current && !done.current && AppState.currentState === "active",
      onError: setCookieError,
    });
    detector.current = watcher;
    void watcher.check();
    const timer = setInterval(() => void watcher.check(), 1000);
    const subscription = AppState.addEventListener("change", (state) => {
      if (state === "active") void watcher.check();
    });
    return () => {
      watcher.stop();
      clearInterval(timer);
      subscription.remove();
      if (detector.current === watcher) detector.current = null;
    };
  }, [network, focused, mutateAsync]);
  function pageChanged(url: string) {
    setPage(url);
    void detector.current?.check();
  }
  function message(data: string) {
    let candidate: unknown;
    try {
      candidate = JSON.parse(data);
    } catch {
      return;
    }
    const parsed = z
      .object({ bearerToken: z.string().min(1), clientToken: z.string().optional() })
      .safeParse(candidate);
    if (parsed.success) {
      token.current = { ...token.current, ...parsed.data };
      void detector.current?.check();
    }
  }
  return (
    <View style={{ flex: 1 }}>
      <View style={{ padding: 12, gap: 8 }}>
        <Label muted>
          {capture.isPending
            ? "Connecting…"
            : `Sign in on ${networkNames[network]}. We'll connect automatically.`}
        </Label>
        <ErrorNotice error={cookieError} />
        {cookieError ? (
          <Button
            title="Retry connection"
            disabled={capture.isPending}
            onPress={() => void detector.current?.check({ retry: true })}
          />
        ) : null}
      </View>
      {capture.isPending ? <Busy /> : null}
      {network === "spotify" ? (
        <EarlyWebView
          style={{ flex: 1 }}
          config={config}
          onMessage={(event) => message(event.nativeEvent.data)}
          onLoad={(event) => pageChanged(event.nativeEvent.url)}
        />
      ) : (
        <WebView
          style={{ flex: 1 }}
          source={{ uri: loginURLs[network] }}
          sharedCookiesEnabled
          thirdPartyCookiesEnabled
          javaScriptEnabled
          onNavigationStateChange={(state) => pageChanged(state.url)}
          onLoadEnd={() => void detector.current?.check()}
          onError={() => pageChanged("")}
          setSupportMultipleWindows={false}
        />
      )}
      <Text style={{ padding: 8, color: "#777", fontSize: 12, ...androidSmallText }}>
        {page ? new URL(page).hostname : "Page failed to load. Go back and try again."}
      </Text>
    </View>
  );
}
