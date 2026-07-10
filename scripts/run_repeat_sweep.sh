#!/usr/bin/env bash
# =============================================================================
# run_repeat_sweep.sh — run the 3-cluster sweep N times and aggregate stats
# =============================================================================
# Purpose: build TRUST in the numbers by repeating the identical sweep and
# reporting mean/median/stddev/CV% per payload per mode, instead of relying on
# a single noisy run.
#
# Usage:
#   RUNS=3 STATE=low  ./scripts/run_repeat_sweep.sh
#   RUNS=3 STATE=high ./scripts/run_repeat_sweep.sh
#   RUNS=3            ./scripts/run_repeat_sweep.sh      # leave config as-is
#
# Env:
#   RUNS           number of repeat sweeps                (default 3)
#   STATE          low|high -> flip dataAggregationLevel first (default: unset)
#   PAYLOAD_SIZES  passed through to the sweep            (default "1024 8192 65536")
#   CONNECTIONS    passed through to the sweep            (default 165)
#   DURATION       passed through to the sweep            (default 90s)
#
# Each individual sweep still writes its own timestamped CSV under
# results/buffer_crossover/. This wrapper collects the CSVs produced during the
# batch and feeds them to aggregate_three_cluster.sh.
# =============================================================================
set -uo pipefail   # NOT -e: one bad sweep must not abort the whole batch

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RUNS="${RUNS:-3}"
STATE="${STATE:-}"
export PAYLOAD_SIZES="${PAYLOAD_SIZES:-1024 8192 65536}"
export CONNECTIONS="${CONNECTIONS:-165}"
export DURATION="${DURATION:-90s}"

NORETINA_CTX="${NORETINA_CTX:-retina-bench-noretina}"
PERF_CTX="${PERF_CTX:-retina-bench-baseline}"
RING_CTX="${RING_CTX:-retina-bench-withretina}"
CONTEXTS=("$NORETINA_CTX" "$PERF_CTX" "$RING_CTX")

OUTDIR="results/buffer_crossover"
mkdir -p "$OUTDIR"
BATCH_ID="$(date -u +%Y%m%dT%H%M%SZ)"
BATCH_TAG="repeat_${STATE:-asis}_${BATCH_ID}"
BATCH_DIR="$OUTDIR/$BATCH_TAG"
mkdir -p "$BATCH_DIR"
MANIFEST="$BATCH_DIR/csvs.txt"
: > "$MANIFEST"

# ---- force-delete stale reuseport pods/jobs on all 3 clusters ---------------
# (empty-CSV aborts are caused by leftover reuseport-recv/reuseport-cli pods)
preclean() {
  for ctx in "${CONTEXTS[@]}"; do
    kubectl --context "$ctx" -n default get pods -o name 2>/dev/null \
      | grep -E 'reuseport-(recv|cli)' \
      | xargs -r kubectl --context "$ctx" -n default delete --force --grace-period=0 --ignore-not-found >/dev/null 2>&1 || true
    kubectl --context "$ctx" -n default get jobs -o name 2>/dev/null \
      | grep -E 'reuseport-cli' \
      | xargs -r kubectl --context "$ctx" -n default delete --ignore-not-found >/dev/null 2>&1 || true
  done
}

echo "########################################################################"
echo "# repeat batch: $BATCH_TAG"
echo "#   RUNS=$RUNS STATE=${STATE:-<unchanged>}"
echo "#   PAYLOAD_SIZES='$PAYLOAD_SIZES' CONNECTIONS=$CONNECTIONS DURATION=$DURATION"
echo "########################################################################"

if [[ -n "$STATE" ]]; then
  echo "--- setting dataAggregationLevel=$STATE on both Retina clusters ---"
  ./scripts/set_dataagg.sh "$STATE" || { echo "set_dataagg failed" >&2; exit 1; }
fi

for i in $(seq 1 "$RUNS"); do
  echo ""
  echo "==================== RUN $i / $RUNS ($BATCH_TAG) ===================="
  preclean

  # snapshot existing summaries so we can identify the new one even if the
  # sweep aborts before printing its "Summary saved to:" line
  before="$(ls -1 "$OUTDIR"/*_three_cluster_summary.csv 2>/dev/null | sort)"

  ./scripts/run_three_cluster_sweep.sh 2>&1 | tee "$BATCH_DIR/run_${i}.log"

  after="$(ls -1 "$OUTDIR"/*_three_cluster_summary.csv 2>/dev/null | sort)"
  newcsv="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | tail -1)"

  if [[ -n "$newcsv" && $(wc -l < "$newcsv") -gt 1 ]]; then
    echo "$newcsv" >> "$MANIFEST"
    echo "run $i -> $newcsv ($(($(wc -l < "$newcsv") - 1)) rows)"
  else
    echo "run $i produced no usable CSV (skipped in aggregation)" >&2
  fi
done

echo ""
echo "==================== BATCH AGGREGATE ($BATCH_TAG) ===================="
mapfile -t CSVS < "$MANIFEST"
if [[ ${#CSVS[@]} -eq 0 ]]; then
  echo "No usable runs in this batch." >&2
  exit 1
fi
python3 ./scripts/aggregate_three_cluster.sh "${CSVS[@]}" | tee "$BATCH_DIR/stats.txt"

echo ""
echo "Batch dir : $BATCH_DIR"
echo "Manifest  : $MANIFEST"
echo "Stats     : $BATCH_DIR/stats.txt"
