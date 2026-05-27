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
# Note: the bash-shell tmux session (`mayor`) is no longer created up-front
# here. The ttyd_loop below owns it via the `creator` argument so that if
# the user exits the bash shell interactively (which kills the tmux
# session), the loop re-creates it instead of permanently 502'ing the
# /city/mayor URL. Agent sessions (gastown__*) are recreated by the gc
# supervisor on their own; we just poll.
# -----------------------------------------------------------------------------

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
# The bash shell session ("mayor") is created+restarted by its loop's
# `creator` argument. The agent sessions (gastown__mayor,
# gastown__deacon, gastown__boot) are spawned by the gc supervisor
# launched above; the loops poll until they exist.
# -----------------------------------------------------------------------------
ttyd_loop() {
  local port="$1" session="$2" creator="${3:-}"
  local basepath="/city/${session}"
  while :; do
    # Wait for the tmux session to exist. If a `creator` command was
    # supplied (used for the bash shell session — agent sessions are
    # supervisor-managed, so they recreate themselves), invoke it whenever
    # the session goes missing. Idempotent: tmux new-session fails fast
    # if the session already exists, which is fine.
    while ! tmux -L city has-session -t "${session}" 2>/dev/null; do
      if [ -n "${creator}" ]; then
        echo "[start-mayor] (re)creating tmux -L city session '${session}'"
        eval "${creator}" || true
        sleep 1
      else
        sleep 3
      fi
    done
    echo "[start-mayor] ttyd: serving ${basepath} on :${port} -> tmux -L city attach -t ${session}"
    ttyd -W -p "${port}" -i 0.0.0.0 --base-path "${basepath}" \
      tmux -L city attach -t "${session}" || true
    sleep 2
  done
}

# Only the bash shell gets a creator — agent tmux sessions are owned by
# the gc supervisor (it spawns/restarts them as it sees fit).
MAYOR_BASH_CREATE="tmux -L city new-session -d -s mayor -x 220 -y 50 \"cd ${CITY} && exec bash -l\""

ttyd_loop 7681 mayor             "${MAYOR_BASH_CREATE}" &
ttyd_loop 7682 gastown__mayor    &
ttyd_loop 7683 gastown__deacon   &
ttyd_loop 7684 gastown__boot     &

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
