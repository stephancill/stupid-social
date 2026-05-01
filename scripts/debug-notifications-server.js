#!/usr/bin/env bun

import { dirname } from "node:path";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";

const port = Number(process.env.PORT || 8787);
const statePath = process.env.DEBUG_NOTIFICATIONS_STATE || "logs/debug-notifications-state.json";
const state = loadState();

const server = Bun.serve({
  hostname: "0.0.0.0",
  port,
  fetch(request) {
    const url = new URL(request.url);
    const requestedAt = new Date();
    console.log(`${requestedAt.toISOString()} ${request.method} ${url.pathname}`);

    if (url.pathname !== "/notifications") {
      return Response.json({ error: "not found" }, { status: 404 });
    }

    const newCount = Math.floor(Math.random() * 6);
    for (let index = 0; index < newCount; index += 1) {
      state.sequence += 1;
      state.notifications.push({
        id: String(state.sequence),
        type: "mention",
        timestamp: new Date(requestedAt.getTime() + index).toISOString(),
        text: `Debug background notification ${state.sequence}`,
        actorUsername: "debug-server",
      });
    }

    saveState(state);

    console.log(
      `${requestedAt.toISOString()} generated ${newCount} new notifications, ${state.notifications.length} total`,
    );

    return Response.json({ notifications: state.notifications });
  },
});

console.log(`Debug notifications server listening on http://0.0.0.0:${server.port}`);
console.log(`Debug notifications state persisted at ${statePath}`);

function loadState() {
  if (!existsSync(statePath)) {
    return { sequence: 0, notifications: [] };
  }

  try {
    return JSON.parse(readFileSync(statePath, "utf8"));
  } catch (error) {
    console.warn(`Could not read ${statePath}; starting with empty debug state.`);
    return { sequence: 0, notifications: [] };
  }
}

function saveState(nextState) {
  mkdirSync(dirname(statePath), { recursive: true });
  writeFileSync(statePath, JSON.stringify(nextState, null, 2));
}
