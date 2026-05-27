#!/bin/bash
# =============================================================================
# start-mayor.sh — boots the gascity controller and exposes per-tmux-session
# PTYs over WebSocket via ttyd, one path per session.
# =============================================================================
# Drop-in copy of the script also distributed via the kylo-proxmox ConfigMap
# at kubernetes/apps/angel-gascity/configmap.yaml. The ConfigMap mount wins
# at runtime (we mount it at /etc/angel-gascity/start-mayor.sh and override
# command), but this baked copy makes the image runnable standalone too.
#
# Runtime expectations (from the Deployment spec):
#   - Pod runs as `gcagent` (UID 1001) — required for `claude
#     --dangerously-skip-permissions` to work
#   - HOME=/home/gcagent (gcagent's real user home — the gc supervisor
#     refuses to start if HOME is overridden). Symlinks below bridge the
#     ephemeral /home/gcagent to the PVC-backed /city.
#   - GC_HOME=/city — the city directory the supervisor manages
#   - PATH includes /city/.local/bin (claude install path under HOME=/city)
#
# URL layout (after this script runs):
#   /                            → 302 → /city/mayor (Traefik middleware)
#   /city/mayor                  → port 7681 (bash shell in tmux session "mayor")
#   /city/gastown__mayor         → port 7682 (mayor agent)
#   /city/gastown__deacon        → port 7683 (deacon agent)
#   /city/gastown__boot          → port 7684 (boot agent)
#
# All sessions live on the `city` tmux socket (-L city). Dynamically-spawned
# agents (gastown__dog-1..3) are reachable via `tmux -L city attach -t
# gastown__dog-1` from inside any of the above shells.
# =============================================================================
set -eu

GCAGENT_HOME="${HOME:-/home/gcagent}"
CITY="${GC_HOME:-/city}"
export HOME="${GCAGENT_HOME}"
export GC_HOME="${CITY}"

# Ensure /city is fully owned by gcagent. fsGroup only sets the group,
# not the owner. Legacy PVC artifacts from when the mayor pod ran as
# root (pre-2026-05-26) are still owned by root; `gc start` calls
# `chmod 700 /city/.beads` which fails without ownership. Use the
# NOPASSWD sudo entry that upstream Dockerfile.base sets up for
# gcagent. Idempotent — does nothing on already-correct trees.
if [ "$(stat -c %u "$CITY/.beads" 2>/dev/null || echo 1001)" != "1001" ]; then
  echo "[start-mayor] chowning $CITY to gcagent:gcagent (legacy root-owned tree)"
  sudo chown -R gcagent:gcagent "$CITY" 2>/dev/null || true
fi

# gc supervisor refuses to start if HOME is overridden away from the
# user's natural home. Bridge gcagent's real home to the PVC so dotfiles
# persist across pod restarts. Each link is only created if the dest
# doesn't already exist.
mkdir -p "$GCAGENT_HOME"
for sub in .claude .claude.json .gitconfig .dolt .gc .beads .npm .local .cache; do
  tgt="$CITY/$sub"
  lnk="$GCAGENT_HOME/$sub"
  if [ -e "$tgt" ] && [ ! -e "$lnk" ]; then
    ln -sf "$tgt" "$lnk"
    echo "[start-mayor] linked $lnk -> $tgt"
  fi
done

# First-boot: stamp out city.toml.
if [ ! -f "$CITY/city.toml" ] && [ -f /etc/angel-gascity/city.toml ]; then
  mkdir -p "$CITY"
  sed "s|__DOLT_ROOT_PASSWORD__|${ANGEL_DOLT_ROOT_PASSWORD:-}|g" \
    /etc/angel-gascity/city.toml > "$CITY/city.toml"
  echo "[start-mayor] wrote $CITY/city.toml"
fi

# Identity for git AND dolt.
git  config --global user.name  "Angel Mayor"                || true
git  config --global user.email "angel-mayor@kylosites.com"  || true
git  config --global --add safe.directory "*"                || true
dolt config --global --add user.name  "Angel Mayor"          || true
dolt config --global --add user.email "angel-mayor@kylosites.com" || true

# Pin the supervisor's HTTP API to a deterministic port (8372 — gc
# docs' default). Without this, gc supervisor picks a random free port
# and writes it into /city/supervisor.toml, which breaks the Service
# definition that expects a known port. Idempotent: only rewrite the
# file if the port differs from 8372.
SUPERVISOR_PORT="${GC_SUPERVISOR_PORT:-8372}"
if [ -f "$CITY/supervisor.toml" ]; then
  CURRENT_PORT="$(awk -F'=' '/^port[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2}' "$CITY/supervisor.toml" | head -1)"
  if [ "$CURRENT_PORT" != "$SUPERVISOR_PORT" ]; then
    echo "[start-mayor] pinning supervisor port -> $SUPERVISOR_PORT (was: ${CURRENT_PORT:-unset})"
    printf '[supervisor]\nport = %s\n' "$SUPERVISOR_PORT" > "$CITY/supervisor.toml"
  fi
else
  echo "[start-mayor] writing $CITY/supervisor.toml (port=$SUPERVISOR_PORT)"
  printf '[supervisor]\nport = %s\n' "$SUPERVISOR_PORT" > "$CITY/supervisor.toml"
fi

# Init the city if needed (gastown pack, via PTY for the wizard).
if [ ! -d "$CITY/.gc" ] && [ ! -d "$CITY/.beads" ]; then
  echo "[start-mayor] running gc init --pack gastown..."
  cd "$CITY"
  if command -v script >/dev/null 2>&1; then
    script -qfc "gc init --pack gastown $CITY" /tmp/gc-init.log </dev/null || true
  else
    gc init --pack gastown --force "$CITY" || true
  fi
fi

# -----------------------------------------------------------------------------
# Create the bash-shell tmux session up-front so the first ttyd client can
# attach immediately. The session_watchdog below polls every 5s and
# recreates it if it ever dies (e.g. user `exit`s the attached shell).
# Agent sessions (gastown__*) are recreated by the gc supervisor itself.
# -----------------------------------------------------------------------------
if ! tmux -L city has-session -t mayor 2>/dev/null; then
  tmux -L city new-session -d -s mayor -x 220 -y 50 "cd $CITY && exec bash -l"
  echo "[start-mayor] tmux -L city session 'mayor' started (bash login shell)"
fi

# -----------------------------------------------------------------------------
# Auto-start the gc supervisor + agents. Idempotent — gc start re-registers
# the city and either starts a fresh supervisor or no-ops if one is
# already running. Skipped if /city isn't initialized.
#
# Requires OAuth credentials at /city/.claude/.credentials.json (set up
# via a one-time `claude /login` from the bash terminal). Without them,
# agents will spawn-fail in a loop but the supervisor itself stays alive.
# -----------------------------------------------------------------------------
if [ -d "$CITY/.gc" ]; then
  echo "[start-mayor] launching gc supervisor for $CITY"
  (cd "$CITY" && gc start "$CITY" 2>&1 | sed 's/^/[gc-start] /') || \
    echo "[start-mayor] gc start exited non-zero (continuing)"
else
  echo "[start-mayor] /city not initialized (no .gc/); skipping auto-start"
fi

# -----------------------------------------------------------------------------
# ttyd processes — one per (well-known) tmux session, each on its own port
# with a path prefix matching the URL. Each loop waits for the target
# session to exist before exec'ing ttyd, then restarts ttyd if it dies.
#
# The bash shell session ("mayor") is created up-front above and kept
# alive by session_watchdog below. The agent sessions (gastown__mayor,
# gastown__deacon, gastown__boot) are spawned by the gc supervisor
# launched above; the loops poll until they exist.
# -----------------------------------------------------------------------------
ttyd_loop() {
  local port="$1" session="$2"
  local basepath="/city/${session}"
  while :; do
    # Wait for the tmux session to exist. (Bash session is owned by
    # session_watchdog below; agent sessions are owned by the gc
    # supervisor.) ttyd itself does NOT exit when its spawned `tmux
    # attach` child errors out — it keeps the WebSocket server alive
    # waiting for the next client — so we can't rely on ttyd exit to
    # trigger re-creation. Hence the dedicated watchdog.
    while ! tmux -L city has-session -t "${session}" 2>/dev/null; do
      sleep 3
    done
    echo "[start-mayor] ttyd: serving ${basepath} on :${port} -> tmux -L city attach -t ${session}"
    ttyd -W -p "${port}" -i 0.0.0.0 --base-path "${basepath}" \
      tmux -L city attach -t "${session}" || true
    sleep 2
  done
}

# Watchdog: keeps the bash `mayor` session alive. If the user exits the
# attached shell (which terminates the tmux session), the next poll
# recreates it. Polls every 5s — cheap, and 5s of degraded /city/mayor
# after an interactive exit is acceptable. Agent sessions are owned by
# the gc supervisor, which handles their own lifecycle.
session_watchdog() {
  local session="$1" creator="$2"
  while :; do
    if ! tmux -L city has-session -t "${session}" 2>/dev/null; then
      echo "[start-mayor] watchdog: (re)creating tmux -L city session '${session}'"
      eval "${creator}" || true
    fi
    sleep 5
  done
}

MAYOR_BASH_CREATE="tmux -L city new-session -d -s mayor -x 220 -y 50 \"cd ${CITY} && exec bash -l\""

session_watchdog mayor "${MAYOR_BASH_CREATE}" &

ttyd_loop 7681 mayor             &
ttyd_loop 7682 gastown__mayor    &
ttyd_loop 7683 gastown__deacon   &
ttyd_loop 7684 gastown__boot     &

# -----------------------------------------------------------------------------
# gc dashboard SPA — static TypeScript bundle compiled into the gc binary.
# Serves at :8080 and tells the SPA to call the supervisor API via the
# public /api/ path so the browser hits the same origin (same authentik
# cookie). Restart-loop so a transient gc failure doesn't permanently
# kill the dashboard.
# -----------------------------------------------------------------------------
DASHBOARD_API_URL="${GC_DASHBOARD_API_URL:-https://angel-gascity.kylosites.com/api}"
(
  while :; do
    echo "[start-mayor] gc dashboard serve --port 8080 --api ${DASHBOARD_API_URL}"
    gc dashboard serve --port 8080 --api "${DASHBOARD_API_URL}" 2>&1 | sed 's/^/[gc-dashboard] /' || true
    sleep 5
  done
) &

# Graceful shutdown: forward SIGTERM to all backgrounded ttyd loops so the
# container exits promptly instead of waiting for the K8s SIGKILL timeout.
shutdown() {
  echo "[start-mayor] caught signal, terminating children"
  kill $(jobs -p) 2>/dev/null || true
  wait
  exit 0
}
trap shutdown TERM INT

# Wait on any one child to exit (which shouldn't happen — the loops are
# infinite). If something does die, we trap+propagate.
wait -n
