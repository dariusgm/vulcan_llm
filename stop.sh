#!/bin/bash
# Stop the llama-server started by ./server.sh: SIGTERM first, SIGKILL if it hangs.
# Usage: ./stop.sh [timeout_seconds]   (default 30)
set -uo pipefail
cd "$(dirname "$0")"

BIN="$PWD/llama.cpp/build/bin/llama-server"
TIMEOUT="${1:-30}"

PIDS=$(pgrep -f "^($BIN|\./llama\.cpp/build/bin/llama-server)( |$)" || true)
if [ -z "$PIDS" ]; then
  echo "llama-server is not running"
  exit 0
fi

echo "Stopping llama-server (PID: $(echo $PIDS)) ..."
kill -TERM $PIDS 2>/dev/null

for _ in $(seq "$((TIMEOUT * 5))"); do
  pgrep -f "^($BIN|\./llama\.cpp/build/bin/llama-server)( |$)" >/dev/null || { echo "Stopped"; exit 0; }
  sleep 0.2
done

echo "Still running after ${TIMEOUT}s, sending SIGKILL" >&2
kill -KILL $PIDS 2>/dev/null
sleep 1
if pgrep -f "^($BIN|\./llama\.cpp/build/bin/llama-server)( |$)" >/dev/null; then
  echo "ERROR: could not stop llama-server" >&2
  exit 1
fi
echo "Killed"
