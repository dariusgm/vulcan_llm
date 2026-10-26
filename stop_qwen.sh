#!/bin/bash
# Stop the Qwen chat server started by ./server_qwen.sh: SIGTERM first, SIGKILL if it hangs.
# Usage: ./stop_qwen.sh [timeout_seconds]   (default 30)
set -uo pipefail
cd "$(dirname "$0")"

PAT="^($PWD/llama\.cpp/build/bin/llama-server|\./llama\.cpp/build/bin/llama-server) .*-hf unsloth/Qwen3\.8-Flash-Next"
TIMEOUT="${1:-30}"

PIDS=$(pgrep -f "$PAT" || true)
if [ -z "$PIDS" ]; then
  echo "qwen server is not running"
  exit 0
fi

echo "Stopping qwen server (PID: $(echo $PIDS)) ..."
kill -TERM $PIDS 2>/dev/null

for _ in $(seq "$((TIMEOUT * 5))"); do
  pgrep -f "$PAT" >/dev/null || { echo "Stopped"; exit 0; }
  sleep 0.2
done

echo "Still running after ${TIMEOUT}s, sending SIGKILL" >&2
kill -KILL $PIDS 2>/dev/null
sleep 1
if pgrep -f "$PAT" >/dev/null; then
  echo "ERROR: could not stop qwen server" >&2
  exit 1
fi
echo "Killed"
