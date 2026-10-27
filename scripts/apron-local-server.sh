#!/bin/sh
# Runs apron-server-go (third-party/apron-server-go) on the LAN for testing the app on a device, with push
# through push.stupidtech.net. State and the server log (which holds email sign-in codes) stay in logs/apron-local/.
# Development only: any origin may connect, and anyone who reads the log can sign in as anyone.
#
#   scripts/apron-local-server.sh            # ws://<this Mac's LAN IP>:8090/ws
#   APRON_PORT=9000 scripts/apron-local-server.sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
state="$root/logs/apron-local"
port=${APRON_PORT:-8090}
mkdir -p "$state/uploads"

(cd "$root/third-party/apron-server-go" && go build -o "$state/aprond" ./cmd/aprond)

ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "<LAN IP>")
echo "Apron test server: ws://$ip:$port/ws (log: $state/aprond.log)"

"$state/aprond" \
  --addr "0.0.0.0:$port" \
  --store "sqlite:$state/aprond.db" \
  --upload.dir "$state/uploads" \
  --allow-any-origin \
  --email.enable --email.sender log \
  --push.vapid-subject https://stupidtech.net \
  2>&1 | tee -a "$state/aprond.log"
