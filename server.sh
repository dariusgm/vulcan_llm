#!/bin/bash
# Start both servers:
#   embedding server (bge-m3, CPU)  -> :9932, started in the background, log in server_bge.log
#   Qwen chat server                -> :9931, started in the foreground (exec), extra args go to it
# Stop both with ./stop.sh
set -euo pipefail
cd "$(dirname "$0")"

./server_bge.sh > server_bge.log 2>&1 &
exec ./server_qwen.sh "$@"
