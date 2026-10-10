import { createHash } from "node:crypto";
const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 8789,
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/redirect")
      return new Response(null, {
        status: 302,
        headers: { Location: "/echo", "Set-Cookie": "probe_redirect=rotated; Path=/; HttpOnly" },
      });
    if (url.pathname === "/cookies") {
      const headers = new Headers();
      headers.append("Set-Cookie", "probe_a=one; Path=/; HttpOnly");
      headers.append("Set-Cookie", "probe_b=two; Path=/; HttpOnly");
      return new Response("ok", { headers });
    }
    if (url.pathname === "/echo")
      return Response.json({
        cookiesCorrect:
          request.headers.get("cookie")?.includes("probe_a=one") &&
          request.headers.get("cookie")?.includes("probe_b=two"),
        csrfCorrect: request.headers.get("x-csrftoken") === "fixture-csrf",
      });
    if (url.pathname === "/upload") {
      const bytes = new Uint8Array(await request.arrayBuffer());
      return Response.json({
        bytes: bytes.length,
        hash: createHash("sha256").update(Array.from(bytes).join(",")).digest("hex"),
      });
    }
    if (url.pathname === "/early")
      return new Response(
        `<!doctype html><meta name="viewport" content="width=device-width"><script>window.fixtureEarly=window.__validationEarly===true;fetch('/echo',{headers:{Authorization:'Bearer fixture-only-token'}});setTimeout(()=>{const data=JSON.stringify({fixture:true,early:window.fixtureEarly,httpOnlyHidden:!document.cookie.includes('probe_http_only')});if(window.ValidationCapture)window.ValidationCapture.postMessage(data);else if(window.ReactNativeWebView)window.ReactNativeWebView.postMessage(data)},300)</script><p>WebView timing test</p>`,
        { headers: { "Content-Type": "text/html", "Cache-Control": "no-store" } },
      );
    return new Response("Not found", { status: 404 });
  },
});
console.log(`Validation fixture listening on 127.0.0.1:${server.port}`);
