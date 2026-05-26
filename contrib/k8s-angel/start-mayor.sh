#!/bin/sh
# =============================================================================
# start-mayor.sh — boots the gascity controller as a tmux session and
# exposes the PTY over WebSocket via ttyd.
# =============================================================================
# Drop-in copy of the script also distributed via the kylo-proxmox ConfigMap
# at kubernetes/apps/angel-gascity/configmap.yaml. The ConfigMap mount wins
# at runtime (we mount it at /etc/angel-gascity/start-mayor.sh and override
# command), but this baked copy makes the image runnable standalone too.
#
# Runtime expectations:
#   - Pod runs as `gcagent` (UID 1001) — required for claude's
#     --dangerously-skip-permissions flag.
#   - HOME=/city — the PVC-backed dir. Lets OAuth credentials
#     ($HOME/.claude/.credentials.json), git config, dolt config, and gc
#     state all survive pod restarts.
#   - PATH must include /city/.local/bin (where claude installs to under
#     HOME=/city). The Deployment env sets PATH; this script trusts it.
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
# user's natural home ("HOME override ... differs from the user home").
# Bridge gcagent's real home to the PVC so dotfiles persist across pod
# restarts. Each link is only created if the dest doesn't already exist.
mkdir -p "$GCAGENT_HOME"
for sub in .claude .claude.json .gitconfig .dolt .gc .beads .npm .local .cache; do
  tgt="$CITY/$sub"
  lnk="$GCAGENT_HOME/$sub"
  if [ -e "$tgt" ] && [ ! -e "$lnk" ]; then
    ln -sf "$tgt" "$lnk"
    echo "[start-mayor] linked $lnk -> $tgt"
  fi
done

# First-boot: stamp out city.toml. The kylo-proxmox ConfigMap provides
# /etc/angel-gascity/city.toml with a __DOLT_ROOT_PASSWORD__ placeholder.
if [ ! -f "$CITY/city.toml" ] && [ -f /etc/angel-gascity/city.toml ]; then
  mkdir -p "$CITY"
  sed "s|__DOLT_ROOT_PASSWORD__|${ANGEL_DOLT_ROOT_PASSWORD:-}|g" \
    /etc/angel-gascity/city.toml > "$CITY/city.toml"
  echo "[start-mayor] wrote $CITY/city.toml"
fi

# Identity for git AND dolt. Both write to $HOME/{.gitconfig,.dolt/} and
# both refuse certain operations without these set.
git  config --global user.name  "Angel Mayor"                || true
git  config --global user.email "angel-mayor@kylosites.com"  || true
git  config --global --add safe.directory "*"                || true
dolt config --global --add user.name  "Angel Mayor"          || true
dolt config --global --add user.email "angel-mayor@kylosites.com" || true

# Initialize the city only if NEITHER marker dir exists. Picks the
# `gastown` pack rather than the default `minimal` pack.
#
# Caveat: upstream `gc init` ignores piped stdin (-> always picks default).
# We use `script -qfc` to give it a real PTY when running non-interactively.
# If `script` isn't installed, fall back to plain init (which may pick the
# wrong pack — operator can re-run `gc init --pack gastown` from the tmux).
if [ ! -d "$CITY/.gc" ] && [ ! -d "$CITY/.beads" ]; then
  echo "[start-mayor] running gc init --pack gastown..."
  cd "$CITY"
  if command -v script >/dev/null 2>&1; then
    script -qfc "gc init --pack gastown $CITY" /tmp/gc-init.log </dev/null || true
  else
    gc init --pack gastown --force "$CITY" || true
  fi
fi

# tmux session. Always a bash login shell — survives any subprocess crash.
# The operator runs `gc start --foreground` themselves from the attached
# terminal once they've completed the one-time `claude /login` OAuth flow.
if ! tmux has-session -t mayor 2>/dev/null; then
  tmux new-session -d -s mayor -x 220 -y 50 "cd $CITY && exec bash -l"
  echo "[start-mayor] tmux 'mayor' session started (bash shell, no auto-gc)"
fi

# Foreground: ttyd serves the mayor tmux session on :7681. -W gives write
# access (operator types into the terminal).
exec ttyd -W -p 7681 -i 0.0.0.0 tmux attach -t mayor
