#!/bin/bash
# Stop the embedding server started by ./server_bge.sh: SIGTERM first, SIGKILL if it hangs.
# Usage: ./stop_bge.sh [timeout_seconds]   (default 30)
set -uo pipefail
cd "$(dirname "$0")"

PAT="^($PWD/llama\.cpp/build/bin/llama-server|\./llama\.cpp/build/bin/llama-server) .*-hf gpustack/bge-m3-GGUF"
TIMEOUT="${1:-30}"

PIDS=$(pgrep -f "$PAT" || true)
if [ -z "$PIDS" ]; then
  echo "bge server is not running"
  exit 0
fi

echo "Stopping bge server (PID: $(echo $PIDS)) ..."
kill -TERM $PIDS 2>/dev/null

for _ in $(seq "$((TIMEOUT * 5))"); do
  pgrep -f "$PAT" >/dev/null || { echo "Stopped"; exit 0; }
  sleep 0.2
done

echo "Still running after ${TIMEOUT}s, sending SIGKILL" >&2
kill -KILL $PIDS 2>/dev/null
sleep 1
if pgrep -f "$PAT" >/dev/null; then
  echo "ERROR: could not stop bge server" >&2
  exit 1
fi
echo "Killed"
