#!/bin/bash
# Stop both servers started by ./server.sh (Qwen chat and bge embedding).
# Usage: ./stop.sh [timeout_seconds]   (default 30)
set -uo pipefail
cd "$(dirname "$0")"

rc=0
./stop_qwen.sh "$@" || rc=1
./stop_bge.sh "$@" || rc=1
exit $rc
