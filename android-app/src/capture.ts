export function captureScript({ native }: { native: boolean }) {
  const send = native
    ? "window.ValidationCapture.postMessage"
    : "window.ReactNativeWebView.postMessage";
  return `(() => {
    window.__validationEarly = true;
    if (!['open.spotify.com', 'accounts.spotify.com', '127.0.0.1'].includes(location.hostname)) return;
    function capture(headers) {
      const h = new Headers(headers || {});
      const authorization = h.get('authorization');
      if (authorization && authorization.startsWith('Bearer ')) {
        ${send}(JSON.stringify({ bearerToken: authorization.slice(7), clientToken: h.get('client-token') || '' }));
      }
    }
    const originalFetch = window.fetch;
    window.fetch = function(input, init) {
      try { capture(init?.headers || (input instanceof Request ? input.headers : undefined)); } catch {}
      return originalFetch.apply(this, arguments);
    };
    const setHeader = XMLHttpRequest.prototype.setRequestHeader;
    XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
      try { capture({ [name]: value }); } catch {}
      return setHeader.apply(this, arguments);
    };
  })(); true;`;
}
