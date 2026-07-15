const metadata = {
  client_id:
    "https://stupid-social-oauth-metadata.stephan-cloudflare.workers.dev/stupid-social/oauth/client-metadata.json",
  application_type: "native",
  client_name: "stupid social",
  client_uri: "https://stupid-social-oauth-metadata.stephan-cloudflare.workers.dev",
  dpop_bound_access_tokens: true,
  grant_types: ["authorization_code", "refresh_token"],
  redirect_uris: [
    "dev.workers.stephan-cloudflare.stupid-social-oauth-metadata:/oauth/bluesky/callback",
  ],
  response_types: ["code"],
  scope: "atproto transition:generic",
  token_endpoint_auth_method: "none",
} as const;

const metadataPath = "/stupid-social/oauth/client-metadata.json";
const metadataBody = JSON.stringify(metadata, null, 2) + "\n";

export default {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname !== metadataPath && url.pathname !== `${metadataPath}/`) {
      return new Response("Not found\n", {
        status: 404,
        headers: {
          "content-type": "text/plain; charset=utf-8",
          "cache-control": "no-store",
        },
      });
    }

    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed\n", {
        status: 405,
        headers: {
          allow: "GET, HEAD",
          "content-type": "text/plain; charset=utf-8",
          "cache-control": "no-store",
        },
      });
    }

    return new Response(request.method === "HEAD" ? null : metadataBody, {
      status: 200,
      headers: {
        "content-type": "application/json; charset=utf-8",
        "cache-control": "public, max-age=300",
      },
    });
  },
} satisfies ExportedHandler;
