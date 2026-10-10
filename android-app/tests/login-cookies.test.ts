import { describe, expect, test } from "bun:test";
import { createLoginCookieDetector, selectedLoginCookies } from "../src/app/loginCookies";

describe("login cookie selection", () => {
  test.each([
    ["x", "auth_token=session; ct0=csrf", { authToken: "session", ct0: "csrf" }],
    [
      "instagram",
      "sessionid=session; csrftoken=csrf; ds_user_id=123; mid=device",
      {
        sessionId: "session",
        csrfToken: "csrf",
        dsUserId: "123",
        mid: "device",
      },
    ],
    [
      "github",
      "user_session=session; __Host-user_session_same_site=secondary",
      {
        userSession: "session",
        sameSiteUserSession: "secondary",
      },
    ],
    [
      "spotify",
      "sp_dc=session; sp_t=device; sp_key=key",
      {
        spDC: "session",
        spT: "device",
        spKey: "key",
      },
    ],
  ] as const)("selects only the required and optional %s cookies", (network, header, expected) => {
    expect(selectedLoginCookies({ network, header: `${header}; unrelated=discard` })).toEqual(
      expected,
    );
  });

  test.each([
    ["x", "auth_token=session; ct0= "],
    ["instagram", "csrftoken=csrf; ds_user_id=123"],
    ["github", "user_session=session"],
    ["spotify", "sp_t=device"],
  ] as const)("waits for a complete %s session", (network, header) => {
    expect(selectedLoginCookies({ network, header })).toBeUndefined();
  });
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

describe("automatic login", () => {
  test("waits silently, connects when cookies arrive, and completes only once", async () => {
    let header = "ct0=csrf";
    const connected: Record<string, string>[] = [],
      errors: unknown[] = [];
    const detector = createLoginCookieDetector({
      network: "x",
      readCookies: async () => header,
      connect: async (value) => {
        connected.push(value);
      },
      isActive: () => true,
      onError: (error) => errors.push(error),
    });
    await detector.check();
    expect(connected).toHaveLength(0);
    expect(errors).toHaveLength(0);
    header = "auth_token=session; ct0=csrf";
    await detector.check();
    await detector.check({ retry: true });
    expect(connected).toEqual([{ authToken: "session", ct0: "csrf" }]);
  });

  test("coalesces checks during cookie reads and account validation", async () => {
    const read = deferred<string>(),
      connection = deferred<void>();
    let reads = 0,
      connections = 0;
    const detector = createLoginCookieDetector({
      network: "x",
      readCookies: () => {
        reads++;
        return read.promise;
      },
      connect: async () => {
        connections++;
        await connection.promise;
      },
      isActive: () => true,
      onError: () => {},
    });
    const pending = detector.check();
    await detector.check();
    read.resolve("auth_token=session; ct0=csrf");
    await Promise.resolve();
    await detector.check({ retry: true });
    expect(reads).toBe(1);
    expect(connections).toBe(1);
    connection.resolve();
    await pending;
  });

  test("a rejected session waits for changed required cookies or explicit retry", async () => {
    let header = "sp_dc=session; sp_t=device",
      connections = 0;
    const errors: unknown[] = [];
    const detector = createLoginCookieDetector({
      network: "spotify",
      readCookies: async () => header,
      connect: async () => {
        connections++;
        throw new Error("Rejected");
      },
      isActive: () => true,
      onError: (error) => errors.push(error),
    });
    await detector.check();
    await detector.check();
    header += "; sp_key=optional-rotation";
    await detector.check();
    expect(connections).toBe(1);
    await detector.check({ retry: true });
    expect(connections).toBe(2);
    header = "sp_dc=fresh-session; sp_t=device";
    await detector.check();
    expect(connections).toBe(3);
    expect(errors).toHaveLength(3);
  });

  test("stopping while reading cookies prevents connection", async () => {
    const read = deferred<string>();
    let connections = 0;
    const detector = createLoginCookieDetector({
      network: "x",
      readCookies: () => read.promise,
      connect: async () => {
        connections++;
      },
      isActive: () => true,
      onError: () => {},
    });
    const pending = detector.check();
    detector.stop();
    read.resolve("auth_token=session; ct0=csrf");
    await pending;
    await detector.check();
    expect(connections).toBe(0);
  });

  test("pauses reads in the background and rejects a read completing after backgrounding", async () => {
    let active = false,
      reads = 0,
      connections = 0;
    const read = deferred<string>();
    const detector = createLoginCookieDetector({
      network: "x",
      readCookies: () => {
        reads++;
        return read.promise;
      },
      connect: async () => {
        connections++;
      },
      isActive: () => active,
      onError: () => {},
    });
    await detector.check();
    expect(reads).toBe(0);
    active = true;
    const pending = detector.check();
    active = false;
    read.resolve("auth_token=session; ct0=csrf");
    await pending;
    expect(connections).toBe(0);
    active = true;
    await detector.check();
    expect(connections).toBe(1);
  });

  test("cookie access failures surface without triggering account validation", async () => {
    const failure = new Error("Cookie access failed");
    const errors: unknown[] = [];
    let connections = 0;
    const detector = createLoginCookieDetector({
      network: "x",
      readCookies: async () => {
        throw failure;
      },
      connect: async () => {
        connections++;
      },
      isActive: () => true,
      onError: (error) => errors.push(error),
    });
    await detector.check();
    expect(errors).toEqual([failure]);
    expect(connections).toBe(0);
  });

  test("a validation failure in the background remains available when the user returns", async () => {
    const connection = deferred<void>();
    let active = true;
    const errors: unknown[] = [];
    const detector = createLoginCookieDetector({
      network: "x",
      readCookies: async () => "auth_token=session; ct0=csrf",
      connect: async () => {
        await connection.promise;
        throw new Error("Reconnect");
      },
      isActive: () => active,
      onError: (error) => errors.push(error),
    });
    const pending = detector.check();
    await Promise.resolve();
    active = false;
    connection.resolve();
    await pending;
    expect(errors).toHaveLength(1);
  });
});
