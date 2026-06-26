#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR_DEFAULT="$ROOT_DIR/results"
SCENARIOS_DIR_DEFAULT="$ROOT_DIR/scenarios"

log() {
  local level="$1"
  shift
  printf '[%s] [%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$level" "$*"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log ERROR "Required command '$cmd' not found in PATH"
    exit 1
  fi
}

ensure_results_dir() {
  local dir="$1"
  mkdir -p "$dir"
}

csv_escape() {
  local value="$1"
  # Escape quotes for CSV
  value="${value//\"/\"\"}"
  printf '%s' "$value"
}

json_get() {
  local file="$1"
  local jq_expr="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r "$jq_expr" "$file" 2>/dev/null || true
  else
    printf ''
  fi
}
