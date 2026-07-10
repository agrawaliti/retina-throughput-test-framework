#!/usr/bin/env bash
# =============================================================================
# set_dataagg.sh — flip dataAggregationLevel on both Retina benchmark clusters
# =============================================================================
# Usage: ./scripts/set_dataagg.sh <low|high>
#
# Extracts the retina-config config.yaml value (jsonpath un-escapes the JSON
# string into real multiline text), rewrites ONLY the dataAggregationLevel line,
# recreates the ConfigMap via apply, then rollout-restarts ds/retina-agent and
# waits for it to settle. Only the two Retina clusters are touched; the
# no-Retina cluster has no agent.
# =============================================================================
set -euo pipefail

LEVEL="${1:-}"
if [[ "$LEVEL" != "low" && "$LEVEL" != "high" ]]; then
  echo "usage: $0 <low|high>" >&2
  exit 2
fi

PERF_CTX="${PERF_CTX:-retina-bench-baseline}"
RING_CTX="${RING_CTX:-retina-bench-withretina}"

# kubectl with retry+backoff to ride out intermittent AKS API-server timeouts.
kctl() {
  local attempt=1 max=5
  while :; do
    kubectl "$@" && return 0
    [[ $attempt -ge $max ]] && return 1
    sleep $((attempt * 3))
    attempt=$((attempt + 1))
  done
}

# Verify the DaemonSet has fully rolled (all desired pods updated & available),
# polling for up to ~7min. Robust against rollout-status i/o blips.
wait_ds_rolled() {
  local ctx="$1" ds="retina-agent" i
  for ((i = 0; i < 42; i++)); do
    read -r desired updated ready <<<"$(kctl --context "$ctx" -n kube-system get ds "$ds" \
      -o jsonpath='{.status.desiredNumberScheduled} {.status.updatedNumberScheduled} {.status.numberReady}' 2>/dev/null)"
    if [[ -n "$desired" && "$desired" == "$updated" && "$desired" == "$ready" && "$desired" -gt 0 ]]; then
      return 0
    fi
    sleep 10
  done
  echo "  WARN: $ctx ds/$ds did not fully roll (desired=$desired updated=$updated ready=$ready)" >&2
  return 1
}

for ctx in "$PERF_CTX" "$RING_CTX"; do
  echo "=== $ctx -> dataAggregationLevel: $LEVEL ==="
  cfg="$(kctl --context "$ctx" -n kube-system get cm retina-config -o jsonpath='{.data.config\.yaml}')"
  if [[ -z "$cfg" ]]; then
    echo "  ERROR: empty retina-config on $ctx" >&2
    exit 1
  fi
  tmp="$(mktemp)"
  printf '%s' "$cfg" | sed "s/^dataAggregationLevel:.*/dataAggregationLevel: $LEVEL/" > "$tmp"

  if ! grep -q "^dataAggregationLevel: $LEVEL\$" "$tmp"; then
    echo "  ERROR: failed to set dataAggregationLevel on $ctx" >&2
    rm -f "$tmp"
    exit 1
  fi

  kubectl --context "$ctx" -n kube-system create configmap retina-config \
    --from-file=config.yaml="$tmp" --dry-run=client -o yaml \
    | kctl --context "$ctx" apply -f - >/dev/null
  rm -f "$tmp"

  kctl --context "$ctx" -n kube-system rollout restart ds/retina-agent >/dev/null
  # rollout status can blip on an API timeout; fall back to polling DS status.
  kctl --context "$ctx" -n kube-system rollout status ds/retina-agent --timeout=420s || wait_ds_rolled "$ctx" || true
  # settle before traffic (matches attach/settle skew note)
  sleep 15
  echo "  applied. current: $(kctl --context "$ctx" -n kube-system get cm retina-config -o jsonpath='{.data.config\.yaml}' | grep -E '^dataAggregationLevel|^packetParserRingBuffer')"
done

echo "dataAggregationLevel=$LEVEL applied to both Retina clusters."
