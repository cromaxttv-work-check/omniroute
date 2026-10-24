#!/usr/bin/env bash
set -eu

cd "$(dirname "$0")/.."

LOG_DIR="$PWD/.logs"
LOG_FILE="$LOG_DIR/omniroute.log"
PID_FILE="$LOG_DIR/omniroute.pid"
SWC_CACHE="$HOME/.swc-cache"
PORT=20128
URL="http://127.0.0.1:$PORT/login"

mkdir -p "$LOG_DIR"
# SWC requires a private, real user-owned cache directory.
mkdir -p "$SWC_CACHE"
chmod 700 "$SWC_CACHE"

is_ready() {
  command -v curl >/dev/null 2>&1 &&
    curl -fsS --max-time 2 "$URL" >/dev/null 2>&1
}

wait_for_ready() {
  local pid="${1:-}"
  local attempt
  for attempt in $(seq 1 30); do
    if is_ready; then
      return 0
    fi
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep 1
  done
  return 1
}

# A responding server is already running; never start a duplicate.
if is_ready; then
  exit 0
fi

# If a recorded process is alive, wait for it instead of falsely reporting
# success immediately. If it never becomes ready, preserve logs for diagnosis.
if [ -f "$PID_FILE" ]; then
  old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    if wait_for_ready "$old_pid"; then
      exit 0
    fi
    printf 'OmniRoute PID %s did not become ready; see %s\n' "$old_pid" "$LOG_FILE" >&2
    tail -n 80 "$LOG_FILE" 2>/dev/null || true
    exit 1
  fi
  rm -f "$PID_FILE"
fi

# Recover an existing server process if the PID file was lost.
if command -v pgrep >/dev/null 2>&1; then
  existing_pid="$(pgrep -f '[n]ode .*scripts/dev/run-next.mjs dev' | head -n 1 || true)"
  if [ -n "$existing_pid" ]; then
    printf '%s\n' "$existing_pid" > "$PID_FILE"
    if wait_for_ready "$existing_pid"; then
      exit 0
    fi
    printf 'Existing OmniRoute process %s did not become ready; see %s\n' "$existing_pid" "$LOG_FILE" >&2
    tail -n 80 "$LOG_FILE" 2>/dev/null || true
    exit 1
  fi
fi

# Keep logs in the workspace (.logs is git-ignored) and pass SWC's cache
# setting to the server process itself.
nohup env PORT="$PORT" SWC_NATIVE_BINDING_CACHE="$SWC_CACHE" OMNIROUTE_USE_TURBOPACK=0 OMNIROUTE_DISABLE_BACKGROUND_SERVICES=1 \
  node --max-old-space-size=4096 scripts/dev/run-next.mjs dev \
  >> "$LOG_FILE" 2>&1 < /dev/null &
server_pid="$!"
printf '%s\n' "$server_pid" > "$PID_FILE"

if wait_for_ready "$server_pid"; then
  exit 0
fi

printf 'OmniRoute failed to become ready within 30 seconds; see %s\n' "$LOG_FILE" >&2
tail -n 80 "$LOG_FILE" 2>/dev/null || true
exit 1
