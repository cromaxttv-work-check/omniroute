#!/usr/bin/env bash
set -eu

cd "$(dirname "$0")/.."
mkdir -p .logs "$HOME/.swc-cache"

LOG_FILE="$PWD/.logs/omniroute.log"
PID_FILE="$PWD/.logs/omniroute.pid"

# If the web app already answers, do not launch a second server.
if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 2 http://127.0.0.1:20128/login >/dev/null 2>&1; then
  exit 0
fi

# Avoid duplicate starts when Codespaces runs this hook more than once.
if [ -f "$PID_FILE" ]; then
  old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    exit 0
  fi
  rm -f "$PID_FILE"
fi

if command -v pgrep >/dev/null 2>&1; then
  existing_pid="$(pgrep -f '[n]ode .*scripts/dev/run-next.mjs dev' | head -n 1 || true)"
  if [ -n "$existing_pid" ]; then
    printf '%s\n' "$existing_pid" > "$PID_FILE"
    exit 0
  fi
fi

# Keep logs in the workspace (the .logs directory is git-ignored).
nohup env PORT=20128 SWC_NATIVE_BINDING_CACHE="$HOME/.swc-cache" \
  node --max-old-space-size=4096 scripts/dev/run-next.mjs dev \
  >> "$LOG_FILE" 2>&1 < /dev/null &
printf '%s\n' "$!" > "$PID_FILE"
