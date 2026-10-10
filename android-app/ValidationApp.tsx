import { useEffect, useRef, useState } from "react";
import { Button, Modal, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { QueryClient, QueryClientProvider, useMutation, useQuery } from "@tanstack/react-query";
import { SafeAreaProvider, SafeAreaView } from "react-native-safe-area-context";
import { WebView } from "react-native-webview";
import { z } from "zod";
import { bridge, EarlyWebView } from "./src/bridge";
import { captureScript } from "./src/capture";
import { captureCookies, importSeed, loginURLs, type Provider } from "./src/storage";
import {
  fixtureURL,
  liveProbe,
  localProbes,
  result,
  safeError,
  uploadInstagramImage,
  type Result,
} from "./src/probes";
import { loginBluesky, probeBlueskyPAR, refreshBluesky } from "./src/oauth";

const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
});
let reportQueue = Promise.resolve();
function publish({ results }: { results: Result[] }) {
  queryClient.setQueryData<Result[]>(["results"], (previous = []) => [
    ...previous.filter((item) => !results.some((r) => r.id === item.id)),
    ...results,
  ]);
  reportQueue = reportQueue.then(() =>
    bridge.writeReport(
      JSON.stringify(
        { environment: bridge.environment(), results: queryClient.getQueryData(["results"]) },
        null,
        2,
      ),
    ),
  );
  return reportQueue;
}
const fixtureMessage = z.object({
  fixture: z.literal(true),
  early: z.boolean(),
  httpOnlyHidden: z.boolean(),
});
const tokenMessage = z.object({
  bearerToken: z.string().min(1),
  clientToken: z.string().optional(),
});
const providers: Provider[] = ["x", "instagram", "github", "spotify"];

function ValidationApp() {
  const [login, setLogin] = useState<Provider | null>(null);
  const [handle, setHandle] = useState("bsky.app");
  const [fixtureRun, setFixtureRun] = useState(0);
  const [nativeLogin, setNativeLogin] = useState(true);
  const token = useRef<{ bearerToken: string; clientToken?: string } | null>(null);
  const captured = useRef(false);
  const started = useRef(false);
  const { data: results = [] } = useQuery<Result[]>({
    queryKey: ["results"],
    queryFn: async () => [],
    initialData: [],
    enabled: false,
  });
  const action = useMutation({
    mutationFn: async ({ id, run }: { id: string; run: () => Promise<Result | Result[]> }) => {
      try {
        const response = await run();
        await publish({ results: Array.isArray(response) ? response : [response] });
      } catch (error) {
        await publish({ results: [result({ id, status: "fail", detail: safeError({ error }) })] });
      }
    },
  });
  const boot = useMutation({
    mutationFn: async () => {
      const count = await importSeed();
      await publish({
        results: [
          result({
            id: "seed-import",
            status: "pass",
            detail: `${count} saved test sessions imported into Android secure storage; no Bluesky tokens copied.`,
          }),
        ],
      });
      await publish({ results: await localProbes() });
      setFixtureRun((value) => value + 1);
      for (const provider of providers) await publish({ results: [await liveProbe({ provider })] });
      await publish({ results: [await probeBlueskyPAR({ handle: "bsky.app" })] });
      await publish({ results: [await refreshBluesky()] });
    },
    onError: (error) => {
      void publish({
        results: [result({ id: "startup", status: "fail", detail: safeError({ error }) })],
      });
    },
  });
  useEffect(() => {
    if (!started.current) {
      started.current = true;
      boot.mutate();
    }
  }, [boot]);
  const capture = useMutation({
    mutationFn: async ({ provider }: { provider: Provider }) => {
      if (captured.current) return;
      if (await captureCookies({ provider, ...token.current })) {
        captured.current = true;
        await publish({
          results: [
            result({
              id: `${provider}-android-login`,
              status: "pass",
              detail:
                "Selected session credentials captured from the Android login WebView and stored securely.",
            }),
          ],
        });
        setLogin(null);
        await publish({ results: [await liveProbe({ provider })] });
      }
    },
    onError: () => {
      void publish({
        results: [
          result({
            id: "login-capture",
            status: "fail",
            detail: "Could not capture/store the session.",
          }),
        ],
      });
    },
  });
  function onMessage({ data }: { data: string }) {
    try {
      const parsed: unknown = JSON.parse(data);
      const candidate = tokenMessage.safeParse(parsed);
      if (login === "spotify" && candidate.success) {
        token.current = candidate.data;
        capture.mutate({ provider: "spotify" });
      }
    } catch {
      /* Unrelated page messages are ignored. */
    }
  }
  function onFixture({ data, kind }: { data: string; kind: string }) {
    try {
      const parsed = fixtureMessage.safeParse(JSON.parse(data));
      if (!parsed.success) return;
      void publish({
        results: [
          result({
            id: kind,
            status: parsed.data.early && parsed.data.httpOnlyHidden ? "pass" : "fail",
            detail: `Early script: ${parsed.data.early}; HttpOnly hidden from page JS: ${parsed.data.httpOnlyHidden}.`,
          }),
        ],
      });
    } catch {
      /* Token-capture fixture messages are not diagnostic output. */
    }
  }
  function openLogin({ provider }: { provider: Provider }) {
    token.current = null;
    captured.current = false;
    setLogin(provider);
  }
  const environment = bridge.environment();
  return (
    <SafeAreaView style={styles.page}>
      <ScrollView contentContainerStyle={styles.content}>
        <Text style={styles.title}>Android validation</Text>
        <Text>
          WebView {environment.webView}. Native early injection: {String(environment.documentStart)}
          .
        </Text>
        <Text>{boot.isPending || action.isPending ? "Checks running…" : "Ready"}</Text>
        <Button title="Run checks again" disabled={boot.isPending} onPress={() => boot.mutate()} />
        <Text style={styles.title}>Account login</Text>
        {providers.map((provider) => (
          <View key={provider} style={styles.row}>
            <Button title={`Log in to ${provider}`} onPress={() => openLogin({ provider })} />
            <Button
              title="Check"
              onPress={() => action.mutate({ id: provider, run: () => liveProbe({ provider }) })}
            />
          </View>
        ))}
        <Button
          title={`Spotify injection: ${nativeLogin ? "native document start" : "standard WebView"}`}
          onPress={() => setNativeLogin(!nativeLogin)}
        />
        <TextInput
          accessibilityLabel="Bluesky handle"
          style={styles.input}
          value={handle}
          onChangeText={setHandle}
          autoCapitalize="none"
          autoCorrect={false}
        />
        <Button
          title="Log in to Bluesky"
          onPress={() =>
            action.mutate({ id: "bluesky-login", run: () => loginBluesky({ handle }) })
          }
        />
        <Button
          title="Refresh Bluesky session"
          onPress={() => action.mutate({ id: "bluesky-session", run: refreshBluesky })}
        />
        <Button
          title="Test Instagram image upload (no publishing)"
          onPress={() => action.mutate({ id: "instagram-upload", run: uploadInstagramImage })}
        />
        <Text style={styles.title}>Results</Text>
        {results.map((item) => (
          <View key={item.id} style={styles.result}>
            <Text style={styles.label}>
              {item.status.toUpperCase()} · {item.id}
            </Text>
            <Text>{item.detail}</Text>
          </View>
        ))}
        {fixtureRun > 0 && (
          <>
            <Text style={styles.label}>Controlled WebView checks</Text>
            <WebView
              key={`stock-${fixtureRun}`}
              style={styles.fixture}
              source={{ uri: `${fixtureURL}/early?stock=${fixtureRun}` }}
              injectedJavaScriptBeforeContentLoaded={captureScript({ native: false })}
              onMessage={(event) =>
                onFixture({ data: event.nativeEvent.data, kind: "standard-webview-document-start" })
              }
            />
            <EarlyWebView
              key={`native-${fixtureRun}`}
              style={styles.fixture}
              config={{
                url: `${fixtureURL}/early?native=${fixtureRun}`,
                script: captureScript({ native: true }),
              }}
              onMessage={(event) =>
                onFixture({ data: event.nativeEvent.data, kind: "native-webview-document-start" })
              }
            />
          </>
        )}
      </ScrollView>
      <Modal visible={login !== null} onRequestClose={() => setLogin(null)}>
        <SafeAreaView style={styles.page}>
          <View style={styles.row}>
            <Button title="Close login" onPress={() => setLogin(null)} />
            <Button
              title="Capture session"
              onPress={() => login && capture.mutate({ provider: login })}
            />
          </View>
          {login &&
            (login === "spotify" && nativeLogin ? (
              <EarlyWebView
                style={styles.webview}
                config={{ url: loginURLs[login], script: captureScript({ native: true }) }}
                onMessage={(event) => onMessage({ data: event.nativeEvent.data })}
                onLoad={() => capture.mutate({ provider: "spotify" })}
              />
            ) : (
              <WebView
                style={styles.webview}
                source={{ uri: loginURLs[login] }}
                javaScriptEnabled
                domStorageEnabled
                thirdPartyCookiesEnabled
                injectedJavaScriptBeforeContentLoaded={
                  login === "spotify" ? captureScript({ native: false }) : undefined
                }
                onMessage={(event) => {
                  if (new URL(event.nativeEvent.url).hostname === "open.spotify.com")
                    onMessage({ data: event.nativeEvent.data });
                }}
                onNavigationStateChange={(state) => {
                  if (
                    !state.loading &&
                    !/login|challenge|checkpoint/.test(new URL(state.url).pathname)
                  )
                    capture.mutate({ provider: login });
                }}
                onShouldStartLoadWithRequest={(request) => /^https?:|^about:/.test(request.url)}
              />
            ))}
        </SafeAreaView>
      </Modal>
    </SafeAreaView>
  );
}
export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <SafeAreaProvider>
        <ValidationApp />
      </SafeAreaProvider>
    </QueryClientProvider>
  );
}
const styles = StyleSheet.create({
  page: { flex: 1, backgroundColor: "#fff" },
  content: { padding: 16, gap: 12 },
  title: { fontSize: 22, fontWeight: "600" },
  label: { fontWeight: "600" },
  result: {
    gap: 4,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderColor: "#ccc",
    paddingBottom: 10,
  },
  row: { flexDirection: "row", justifyContent: "space-between" },
  input: { borderWidth: 1, borderColor: "#aaa", padding: 10 },
  fixture: { height: 80, flex: 0 },
  webview: { flex: 1 },
});
