import { fetch } from "expo/fetch";
import * as Crypto from "expo-crypto";
import * as WebBrowser from "expo-web-browser";
import { File } from "expo-file-system";
import { credentials, saveCredentials, generation } from "./app/storage";
import { configureClientRuntime } from "./clientRuntime";

configureClientRuntime({
  runtime: {
    fetch: (url, init) => fetch(url, init),
    credentials,
    saveCredentials,
    generation,
    randomUUID: () => Crypto.randomUUID(),
    randomBytes: (size) => Crypto.getRandomBytes(size),
    readFile: ({ uri }) => new File(uri).bytes(),
    openAuthSession: async ({ url, redirectURI }) => {
      const result = await WebBrowser.openAuthSessionAsync(url, redirectURI);
      return result.type === "success" ? result : { type: "cancel" };
    },
  },
});
