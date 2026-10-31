#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_DIR="$ROOT_DIR/.logs"
LOG_FILE="$LOG_DIR/omniroute.log"
PID_FILE="$LOG_DIR/omniroute.pid"
LOCK_FILE="$LOG_DIR/omniroute-start.lock"

PORT="${PORT:-20128}"
HEALTH_URL="http://127.0.0.1:${PORT}/healthz"
SWC_CACHE="${SWC_NATIVE_BINDING_CACHE:-$HOME/.swc-cache}"
MAX_ATTEMPTS=120
SLEEP_SECONDS=2

mkdir -p "$LOG_DIR"

if ! command -v curl >/dev/null 2>&1; then
  echo "OmniRoute startup: curl is required for the /healthz readiness check." >&2
  exit 1
fi
if ! command -v flock >/dev/null 2>&1; then
  echo "OmniRoute startup: flock is required to prevent duplicate server starts." >&2
  exit 1
fi
if [[ "$SWC_CACHE" != /* ]]; then
  echo "OmniRoute startup: SWC_NATIVE_BINDING_CACHE must be an absolute path." >&2
  exit 1
fi

mkdir -p "$SWC_CACHE"
chmod 700 "$SWC_CACHE"

# Serialize postStartCommand and postAttachCommand. The second hook waits for
# the first rather than racing it and launching a duplicate Next.js process.
exec 9>"$LOCK_FILE"
flock 9

is_ready() {
  curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1
}

is_server_pid() {
  local pid="$1"
  local command_line
  command_line="$(ps -p "$pid" -o args= 2>/dev/null || true)"
  [[ "$command_line" == *"scripts/dev/run-next.mjs dev"* ]]
}

wait_for_ready() {
  local pid="$1"
  local attempt
  for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
    if is_ready; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep "$SLEEP_SECONDS"
  done
  return 1
}

# A healthy server is the only condition considered a successful start.
if is_ready; then
  exit 0
fi

# Reuse a process recorded by an earlier hook only if it is still the OmniRoute
# dev server. A stale or recycled PID must never suppress a fresh start.
if [[ -f "$PID_FILE" ]]; then
  old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    if is_server_pid "$old_pid"; then
      if wait_for_ready "$old_pid"; then
        exit 0
      fi
      echo "OmniRoute PID $old_pid is alive but /healthz did not become ready." >&2
      tail -n 100 "$LOG_FILE" 2>/dev/null || true
      exit 1
    fi
  fi
  rm -f "$PID_FILE"
fi

# Recover an existing process if the PID file was lost.
existing_pid="$(pgrep -f '[n]ode .*scripts/dev/run-next\.mjs dev' | head -n 1 || true)"
if [[ -n "$existing_pid" ]]; then
  printf '%s\n' "$existing_pid" > "$PID_FILE"
  if wait_for_ready "$existing_pid"; then
    exit 0
  fi
  echo "Existing OmniRoute process $existing_pid did not become healthy." >&2
  tail -n 100 "$LOG_FILE" 2>/dev/null || true
  exit 1
fi

# Keep the latest log and one bounded-size previous log.
if [[ -f "$LOG_FILE" ]] && [[ "$(wc -c < "$LOG_FILE")" -gt 10485760 ]]; then
  mv -f "$LOG_FILE" "$LOG_FILE.1"
fi

# Webpack is selected deliberately for Codespaces stability; SWC gets a
# private, persistent cache under the Codespaces user's home directory.
nohup env PORT="$PORT" SWC_NATIVE_BINDING_CACHE="$SWC_CACHE" OMNIROUTE_USE_TURBOPACK=0 \
  node --max-old-space-size=4096 scripts/dev/run-next.mjs dev \
  >> "$LOG_FILE" 2>&1 < /dev/null &
server_pid="$!"
printf '%s\n' "$server_pid" > "$PID_FILE.tmp"
mv -f "$PID_FILE.tmp" "$PID_FILE"

if wait_for_ready "$server_pid"; then
  echo "OmniRoute is healthy at $HEALTH_URL"
  exit 0
fi

echo "OmniRoute did not become healthy within $((MAX_ATTEMPTS * SLEEP_SECONDS)) seconds." >&2
echo "The process was left running for diagnosis; log: $LOG_FILE" >&2
tail -n 100 "$LOG_FILE" 2>/dev/null || true
exit 1
