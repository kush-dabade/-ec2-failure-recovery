#!/usr/bin/env bash
# Evidence tool: run a read-only AWS CLI command, save its exact output with a
# timestamp header to evidence/raw/<name>.txt, and render it to evidence/<name>.png.
#   cap.sh <name> "<title>" <command...>
set -uo pipefail
EV="$(cd "$(dirname "$0")/.." && pwd)"
SP=/tmp/claude-1000/-home-kush-projects-vm-failure/68519b09-a86b-44f6-92f9-ab4d3d0dbd8f/scratchpad
name="$1"; title="$2"; shift 2
export AWS_REGION=ap-south-1 AWS_PAGER=""
{
  echo "# captured $(date -u +%Y-%m-%dT%H:%M:%SZ) ($(TZ=Asia/Kolkata date '+%H:%M:%S IST'))"
  echo "\$ $*"
  "$@" 2>&1
} > "$EV/raw/$name.txt"
NODE_PATH="$SP/pw/node_modules" node "$EV/tools/render_cli.js" "$EV/raw/$name.txt" "$EV/$name.png" "$title"
echo "captured $name"
