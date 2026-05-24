#!/bin/sh
# =============================================================================
# start-mayor.sh — boots the gascity controller as a tmux session and
# exposes the PTY over WebSocket via ttyd.
# =============================================================================
# Drop-in copy of the script also distributed via the kylo-proxmox ConfigMap
# at kubernetes/apps/angel-gascity/configmap.yaml. The ConfigMap mount wins
# at runtime (we mount it at /etc/angel-gascity/start-mayor.sh and override
# command), but this baked copy makes the image runnable standalone too.
# =============================================================================
set -eu

: "${HOME:?HOME must be set (point at /city)}"
CITY=/city

# First-boot: stamp out city.toml. The kylo-proxmox ConfigMap provides
# /etc/angel-gascity/city.toml with a __DOLT_ROOT_PASSWORD__ placeholder.
if [ ! -f "$CITY/city.toml" ] && [ -f /etc/angel-gascity/city.toml ]; then
  mkdir -p "$CITY"
  sed "s|__DOLT_ROOT_PASSWORD__|${ANGEL_DOLT_ROOT_PASSWORD:-}|g" \
    /etc/angel-gascity/city.toml > "$CITY/city.toml"
  echo "[start-mayor] wrote $CITY/city.toml"
fi

# git config so `gc init` doesn't refuse
git config --global user.name  "Angel Mayor" || true
git config --global user.email "angel-mayor@kylosites.com" || true
git config --global --add safe.directory "$CITY" || true

# Initialize the city if needed (controller image's CMD also does this,
# but doing it here lets us boot before anyone attaches).
if [ ! -d "$CITY/.gc" ] && [ ! -d "$CITY/.beads" ]; then
  cd "$CITY"
  gc init --force || true
fi

# Start the controller in a detached tmux session named "mayor"
if ! tmux has-session -t mayor 2>/dev/null; then
  tmux new-session -d -s mayor -x 220 -y 50 \
    "cd $CITY && gc start --foreground $CITY; exec /bin/bash"
  echo "[start-mayor] tmux 'mayor' session started"
fi

# Foreground: ttyd serves the mayor tmux session on :7681.
# -W enables write access (the user needs to interact with the mayor).
exec ttyd -W -p 7681 -i 0.0.0.0 tmux attach -t mayor
