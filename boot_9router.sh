#!/usr/bin/env bash
set -e

echo "=== [$(date -u)] Booting 9Router VPS ==="

# 1. Install cloudflared
if ! command -v cloudflared &>/dev/null; then
  echo "Installing cloudflared..."
  curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
fi

mkdir -p data /tmp/vps-state

# 2. Restore state from git state branch
echo "Checking state branch..."
FIRST_BOOT=0
if python3 vps_state.py restore; then
  echo "State restored from state branch!"
else
  echo "No existing state on state branch. First boot initialization..."
  FIRST_BOOT=1
fi

# Ensure password is set to 6755 hash in sqlite
if [ -f "data/db/data.sqlite" ]; then
  python3 -c '
import sqlite3, json
try:
    con = sqlite3.connect("data/db/data.sqlite")
    row = con.execute("SELECT data FROM settings WHERE id = 1").fetchone()
    if row:
        d = json.loads(row[0])
        d["password"] = "$2b$10$b8z3OXbOquupKmeYYTape.5MxvqUyO2b1meEGQJ8trgvC7pW38S2O"
        con.execute("UPDATE settings SET data = ? WHERE id = 1", (json.dumps(d),))
        con.commit()
        print("Enforced password = 6755 in data.sqlite")
except Exception as e:
    print("sqlite patch note:", e)
'
fi

# 3. Build/Run latest 9router container (v0.5.81)
echo "Building/Starting 9router v0.5.81 container..."
docker build -t 9router:0.5.81 .
docker run -d --name 9router \
  --restart always \
  -p 20128:20128 \
  -v "$(pwd)/data:/app/data" \
  -e DATA_DIR=/app/data \
  -e HOSTNAME=0.0.0.0 \
  -e PORT=20128 \
  -e INITIAL_PASSWORD=6755 \
  -e JWT_SECRET=p387oefxdgqcqbzl \
  -e API_KEY_SECRET=roiwnz5g6nb80mpd \
  -e MACHINE_ID_SALT=6d88ebv9lb1ae61n \
  -e NODE_ENV=production \
  9router:0.5.81

# 4. Wait for 9router health
echo "Waiting for 9router to answer..."
for i in {1..30}; do
  if curl -sf http://127.0.0.1:20128/api/version &>/dev/null; then
    echo "9router is UP and healthy!"
    break
  fi
  sleep 2
done

# 5. If first boot, seed database
if [ "$FIRST_BOOT" -eq 1 ]; then
  echo "Seeding database with providers, models, combos..."
  python3 seed_9router.py
  sleep 5
fi

# 6. Start cloudflared tunnel
echo "Starting Cloudflare tunnel..."
rm -f cloudflared.log
cloudflared tunnel --url http://127.0.0.1:20128 --no-autoupdate > cloudflared.log 2>&1 &
CF_PID=$!

echo "Waiting for tunnel URL..."
TUNNEL_URL=""
for i in {1..40}; do
  TUNNEL_URL=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' cloudflared.log | head -n1 || true)
  if [ -n "$TUNNEL_URL" ]; then
    echo "Found Tunnel URL: $TUNNEL_URL"
    break
  fi
  sleep 1
done

if [ -z "$TUNNEL_URL" ]; then
  echo "ERROR: Cloudflare tunnel failed to produce a URL!"
  cat cloudflared.log
  exit 1
fi

# 7. Update Cloudflare KV namespace with the new Tunnel URL
echo "Updating Cloudflare KV..."
curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces/$CF_KV_NAMESPACE/values/current_url" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  --data "$TUNNEL_URL"
echo ""

PERM_URL="https://9router-stable.qasmynhmdmhdy.workers.dev"

# 8. Create boot receipt
cat << EOF > /tmp/vps-state/boot_receipt.txt
=== $(date -u +'%Y-%m-%dT%H:%M:%SZ') 9Router VPS Boot Receipt ===
OK  Docker: 9router running (port 20128)
OK  Tunnel: $TUNNEL_URL
OK  Cloudflare Worker: $PERM_URL
EOF

echo "=== BOOT COMPLETE ==="
cat /tmp/vps-state/boot_receipt.txt

# Helper function to checkpoint SQLite and flush WAL
flush_sqlite() {
  docker exec 9router node -e '
    try {
      const sqlite3 = require("better-sqlite3");
      const db = new sqlite3("/app/data/db/data.sqlite");
      db.pragma("wal_checkpoint(TRUNCATE)");
      db.close();
    } catch(e) {}
  ' 2>/dev/null || true
}

# 9. Initial state push
flush_sqlite
python3 vps_state.py push-once

# 10. Start background periodic state sync
sync_loop() {
  while true; do
    sleep 60
    flush_sqlite
    python3 vps_state.py push-once || true
  done
}
sync_loop &
SYNC_LOOP_PID=$!

# 11. Shift monitor loop (267 minutes = 16020 seconds)
START_TIME=$(date +%s)
MAX_RUNTIME=16020

echo "Entering shift monitor loop (267m)..."
while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TIME))
  if [ "$ELAPSED" -ge "$MAX_RUNTIME" ]; then
    echo "Shift duration reached (267m). Handing over cleanly."
    break
  fi

  if ! docker ps | grep -q 9router; then
    echo "WARNING: 9router container died! Restarting..."
    docker restart 9router || true
  fi

  if ! kill -0 "$CF_PID" 2>/dev/null; then
    echo "WARNING: cloudflared died! Restarting..."
    cloudflared tunnel --url http://127.0.0.1:20128 --no-autoupdate > cloudflared.log 2>&1 &
    CF_PID=$!
    sleep 5
    NEW_TUNNEL=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' cloudflared.log | head -n1 || true)
    if [ -n "$NEW_TUNNEL" ]; then
      curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces/$CF_KV_NAMESPACE/values/current_url" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        --data "$NEW_TUNNEL"
    fi
  fi

  sleep 30
done

kill "$SYNC_LOOP_PID" 2>/dev/null || true
flush_sqlite
python3 vps_state.py push-once
echo "Shift ended cleanly."
