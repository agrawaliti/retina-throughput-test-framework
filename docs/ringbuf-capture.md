# Retina Ring Buffer Benchmark & CPU Flamegraph Capture

## Table of Contents

1. [Overview](#overview)
2. [How the Flamegraph Is Captured](#how-the-flamegraph-is-captured)
3. [Adapting to Any Node or NIC](#adapting-to-any-node-or-nic)
4. [Quick-start Commands](#quick-start-commands)
5. [Full CLI Reference](#full-cli-reference)
6. [Output Directory Structure](#output-directory-structure)
7. [Viewing the Flamegraph](#viewing-the-flamegraph)
8. [Reading the Flamegraph](#reading-the-flamegraph)
9. [Benchmark Results (2026-06-25)](#benchmark-results-2026-06-25)
10. [Known Issues & Workarounds](#known-issues--workarounds)

---

## Overview

`scripts/run_ringbuf_capture.sh` does two things in parallel:

1. **Benchmarks** TCP throughput through a SO_REUSEPORT receiver — once with Retina
   packet-parser ring buffer **disabled** (baseline) and once with it **enabled**
2. **Profiles** the receiver node with `perf record` while traffic is live, then
   converts the recording into a CPU **flamegraph SVG** you can open in any browser

Both phases share the same receiver and produce a single timestamped result directory.

---

## How the Flamegraph Is Captured

Understanding the capture pipeline helps when debugging failures or adapting parameters.

### Step-by-step pipeline

```
run_ringbuf_capture.sh
│
├── kubectl create privileged pod on receiver node
│   │
│   │  Inside the pod (ubuntu:22.04 image):
│   │
│   ├── 1. Resolve perf binary
│   │       The host kernel is 5.15.0-1114-azure. The standard perf binary
│   │       lives at:
│   │         /usr/lib/linux-tools/5.15.0-1114-azure/perf   (symlink)
│   │         → /usr/lib/linux-azure-tools-5.15.0-1114/perf (real file)
│   │
│   │       The pod cannot just call this binary directly because it links
│   │       against host glibc. Instead the pod uses:
│   │
│   │         chroot /host-root /usr/lib/linux-tools/5.15.0-1114-azure/perf
│   │
│   │       where /host-root is the host filesystem mounted writable into
│   │       the pod. This makes all host libraries visible to perf.
│   │
│   ├── 2. Download FlameGraph scripts
│   │       curl from brendangregg/FlameGraph on GitHub:
│   │         stackcollapse-perf.pl  → /usr/local/bin/
│   │         flamegraph.pl          → /usr/local/bin/
│   │
│   ├── 3. Snapshot system state (before)
│   │       /proc/softirqs   → softirqs.before.txt
│   │       /proc/interrupts → interrupts.before.txt
│   │       bpftool prog/map/link/net show → bpftool.*.before.txt
│   │
│   ├── 4. Start perf record (background)
│   │
│   │       chroot /host-root perf record \
│   │         -a                    # all CPUs (system-wide)
│   │         -g                    # collect call graphs
│   │         --call-graph fp       # use frame-pointer unwinding
│   │         -e cpu-clock          # software event (works without
│   │         -F 99                 # hardware PMU), 99 Hz sampling
│   │         -o /tmp/ringbuf-perf-<TS>.data \
│   │         -- sleep <capture-duration>
│   │
│   │       Output is written to host /tmp (writable via the chroot mount).
│   │       95 057 samples captured in ~13 MB in the reference run.
│   │
│   ├── 5. Poll softirq counters every <interval> seconds → samples.csv
│   │       columns: timestamp, NET_RX_total, NET_TX_total
│   │
│   ├── 6. Wait for perf to finish, copy perf.data → /capture/<TS>/
│   │
│   ├── 7. Generate perf.script.txt
│   │
│   │       chroot /host-root perf script \
│   │         -i /tmp/ringbuf-perf-<TS>.data
│   │
│   │       Produces 964 431 lines / 50 MB of raw stack traces.
│   │
│   ├── 8. Generate flamegraph
│   │
│   │       stackcollapse-perf.pl < perf.script.txt > perf.folded.txt
│   │       flamegraph.pl perf.folded.txt > flamegraph.svg
│   │
│   │       Folded stacks: 167 KB   Flamegraph SVG: 44 KB
│   │
│   ├── 9. Snapshot system state (after)
│   │       softirqs.after.txt, interrupts.after.txt, bpftool.*.after.txt
│   │
│   └── 10. Copy /capture/<TS>/ → /host-capture/ (host-path volume)
│            then sleep 180 s so the wrapper can kubectl cp it out
│
├── (parallel) run_reuseport_ab.sh
│       Baseline phase: Retina ring buffer disabled
│       With-Retina phase: Retina ring buffer enabled
│       Each phase: 4 pods × 8 connections = 32 TCP streams, 10 s
│
└── kubectl cp /capture/<TS>/ → local results/ringbuf_capture/<RUN_ID>_capture/pod_capture_<TS>/
```

### Why `cpu-clock` and not `cycles`?

`-e cycles` requires the hardware PMU which is often blocked inside containers
and VMs (returns EACCES). `-e cpu-clock` is a software event implemented by
the kernel itself — it works reliably on all AKS nodes without extra privileges
beyond the `privileged: true` pod security context.

### Why frame-pointer unwinding (`--call-graph fp`)?

`--call-graph dwarf` produces richer stacks but is 5–10× slower and produces
much larger data files. For a 32-CPU system-wide capture at 99 Hz, DWARF
unwinding caused perf to run out of memory. Frame-pointer unwinding is fast,
cheap, and sufficient to see the kernel and user-space networking paths.
The Go receiver binary is compiled with frame pointers (Go always does), so
call stacks are complete.

---

## Adapting to Any Node or NIC

### Step 1 — Find your target node

```bash
kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,POOL:.metadata.labels.agentpool,SKU:.metadata.labels.beta\.kubernetes\.io/instance-type'
```

Example output:
```
NAME                              POOL     SKU
aks-sysd64-25644950-vmss000000    sysd64   Standard_D64s_v3
aks-sysd64-25644950-vmss000001    sysd64   Standard_D64s_v3
aks-usr32-25342902-vmss000000     usr32    Standard_D32s_v3
aks-usr32-25342902-vmss000001     usr32    Standard_D32s_v3
```

Pick the node you want to profile. The script pins both the benchmark receiver
pod and the capture pod to this node with `nodeSelector`.

### Step 2 — Find the NIC name

SSH into the node via `kubectl debug` or `kubectl node-shell`:

```bash
# One-liner: run ip link inside a privileged pod on your chosen node
kubectl run nic-probe --rm -it --restart=Never \
  --image=ubuntu:22.04 \
  --overrides="{
    \"spec\": {
      \"nodeSelector\": {\"kubernetes.io/hostname\": \"<YOUR_NODE>\"},
      \"hostNetwork\": true
    }
  }" \
  -- ip -o link show | awk -F': ' '{print $2}' | grep -v lo
```

Typical output on AKS:
```
eth0          ← primary NIC for most node SKUs
enP40153s1    ← SR-IOV NIC on Standard_D32s_v3 (this cluster)
```

Use the NIC name you see for `--nic`.

### Step 3 — Check kernel version on the node

```bash
kubectl run kernel-check --rm -it --restart=Never \
  --image=ubuntu:22.04 \
  --overrides="{
    \"spec\": {
      \"nodeSelector\": {\"kubernetes.io/hostname\": \"<YOUR_NODE>\"},
      \"hostPID\": true
    }
  }" \
  -- uname -r
```

The script discovers this automatically via `uname -r` inside the chroot, so
you don't need to pass it — but knowing it helps if perf fails to locate its
binary.

### Step 4 — Verify perf is installed on the host

```bash
kubectl run perf-check --rm -it --restart=Never \
  --image=ubuntu:22.04 \
  --privileged \
  --overrides="{
    \"spec\": {
      \"nodeSelector\": {\"kubernetes.io/hostname\": \"<YOUR_NODE>\"},
      \"hostPID\": true,
      \"volumes\": [{\"name\": \"root\", \"hostPath\": {\"path\": \"/\"}}],
      \"containers\": [{
        \"name\": \"c\",
        \"image\": \"ubuntu:22.04\",
        \"securityContext\": {\"privileged\": true},
        \"volumeMounts\": [{\"name\": \"root\", \"mountPath\": \"/host-root\"}]
      }]
    }
  }" \
  -- ls -la /host-root/usr/lib/linux-tools/
```

You should see a directory named after the kernel version containing a `perf`
symlink. If the directory is empty, `linux-azure-tools-*` is not installed on
the host and profiling will fail.

### Step 5 — Run

Replace the `--node` and `--nic` values. Everything else has sensible defaults.

```bash
./scripts/run_ringbuf_capture.sh \
  --node <YOUR_NODE>  \
  --nic  <YOUR_NIC>   \
  --client-pods         4   \
  --connections-per-pod 8   \
  --duration            10s \
  --capture-duration    30
```

#### Longer / heavier capture

For a deeper profiling run with more traffic and a longer perf window:

```bash
./scripts/run_ringbuf_capture.sh \
  --node aks-usr32-25342902-vmss000000 \
  --nic  enP40153s1 \
  --client-pods         8   \
  --connections-per-pod 16  \
  --duration            30s \
  --listeners           32  \
  --workers             128 \
  --capture-duration    60  \
  --capture-interval    1
```

#### Profile-only (no benchmark, just capture idle system)

There is no profile-only mode in the script, but you can run the capture pod
manually:

```bash
NODE=aks-usr32-25342902-vmss000000

kubectl run perf-capture --rm --restart=Never \
  --image=ubuntu:22.04 \
  --privileged \
  --overrides="{
    \"spec\": {
      \"hostPID\": true,
      \"nodeSelector\": {\"kubernetes.io/hostname\": \"$NODE\"},
      \"volumes\": [
        {\"name\": \"root\",    \"hostPath\": {\"path\": \"/\"}},
        {\"name\": \"capture\", \"emptyDir\": {}}
      ],
      \"containers\": [{
        \"name\": \"c\",
        \"image\": \"ubuntu:22.04\",
        \"securityContext\": {\"privileged\": true},
        \"volumeMounts\": [
          {\"name\": \"root\",    \"mountPath\": \"/host-root\"},
          {\"name\": \"capture\", \"mountPath\": \"/capture\"}
        ]
      }]
    }
  }" \
  -- bash -c '
    K=$(chroot /host-root uname -r)
    PERF="chroot /host-root /usr/lib/linux-tools/${K}/perf"
    apt-get update -qq && apt-get install -y --no-install-recommends perl curl -qq
    curl -fsSL https://raw.githubusercontent.com/brendangregg/FlameGraph/master/stackcollapse-perf.pl -o /usr/local/bin/stackcollapse-perf.pl
    curl -fsSL https://raw.githubusercontent.com/brendangregg/FlameGraph/master/flamegraph.pl -o /usr/local/bin/flamegraph.pl
    chmod +x /usr/local/bin/stackcollapse-perf.pl /usr/local/bin/flamegraph.pl
    eval $PERF record -a -g --call-graph fp -e cpu-clock -F 99 \
      -o /tmp/perf.data -- sleep 30
    eval $PERF script -i /tmp/perf.data > /capture/perf.script.txt
    stackcollapse-perf.pl < /capture/perf.script.txt > /capture/perf.folded.txt
    flamegraph.pl /capture/perf.folded.txt > /capture/flamegraph.svg
    echo done; sleep 300
  '

# While the pod sleeps, copy out:
kubectl cp default/perf-capture:/capture/flamegraph.svg ./flamegraph.svg
```

---

## Quick-start Commands

### This cluster (Standard_D32s_v3, NIC enP40153s1)

```bash
cd /home/itiagrawal/Projects/iperf3-test

./scripts/run_ringbuf_capture.sh \
  --node aks-usr32-25342902-vmss000000 \
  --nic  enP40153s1 \
  --client-pods 4 --connections-per-pod 8 \
  --duration 10s --listeners 16 --workers 64 \
  --capture-duration 30 --capture-interval 1
```

### Different node in the same pool (vmss000001)

```bash
./scripts/run_ringbuf_capture.sh \
  --node aks-usr32-25342902-vmss000001 \
  --nic  enP40153s1 \
  --client-pods 4 --connections-per-pod 8 \
  --duration 10s --listeners 16 --workers 64 \
  --capture-duration 30
```

### D64s_v3 node pool (sysd64)

```bash
# Find the NIC first (likely eth0 on D64):
NODE=aks-sysd64-25644950-vmss000000

./scripts/run_ringbuf_capture.sh \
  --node $NODE \
  --nic  eth0 \
  --client-pods 8 --connections-per-pod 16 \
  --duration 30s --listeners 32 --workers 128 \
  --capture-duration 60
```

---

## Full CLI Reference

| Flag | Default | Description |
|---|---|---|
| `--node` | *(required)* | Node hostname for receiver pod and capture pod (must match `kubernetes.io/hostname` label) |
| `--nic` | *(required)* | NIC name on the node — used as metadata only; does not change what perf captures (perf profiles all CPUs system-wide) |
| `--client-pods` | `4` | Number of client pods sending traffic |
| `--connections-per-pod` | `8` | Long-lived TCP connections per client pod |
| `--duration` | `10s` | Benchmark duration per phase (baseline + with-Retina) |
| `--listeners` | `16` | SO_REUSEPORT listener goroutines on receiver |
| `--workers` | `64` | Worker goroutines on receiver |
| `--payload-bytes` | `65536` | Client write buffer size (64 KB) |
| `--capture-duration` | `30` | Seconds to run `perf record` — should be ≥ benchmark `--duration` |
| `--capture-interval` | `1` | Softirq polling interval in seconds for `samples.csv` |
| `--capture-tag` | `ringbuf` | Free-text label stored in `meta.env` for identification |
| `--results-dir` | `results/ringbuf_capture` | Root directory for all output |
| `--pod-image` | `ubuntu:22.04` | Base image for the capture pod |

**Tip:** Set `--capture-duration` to at least `--duration` × 2 (in seconds) so
perf is recording during both the baseline and with-Retina benchmark phases.

---

## Output Directory Structure

```
results/ringbuf_capture/
│
├── <RUN_ID>_ringbuf_capture.log      # wrapper stdout (benchmark output + capture log)
├── <RUN_ID>_capture.log              # pod stdout collected via kubectl logs
│
├── <RUN_ID>_capture/
│   ├── capture-pod.yaml              # exact pod manifest (re-runnable)
│   └── pod_capture_<TS>/             # artifacts kubectl cp'd from the pod
│       │
│       ├── flamegraph.svg            # ★ interactive CPU flamegraph — open in browser
│       ├── perf.data                 # raw recording (14 MB, 95 057 samples)
│       ├── perf.folded.txt           # folded stacks (167 KB, input to flamegraph.pl)
│       ├── perf.script.txt           # full perf script output (50 MB, 964 431 lines)
│       │
│       ├── perf.record.err.txt       # stderr from perf record (check for errors)
│       ├── perf.record.out.txt       # stdout from perf record (sample counts)
│       ├── perf.script.err.txt       # stderr from perf script
│       ├── flamegraph.err.txt        # stderr from flamegraph.pl
│       ├── stackcollapse.err.txt     # stderr from stackcollapse-perf.pl
│       │
│       ├── bpftool.prog.before.txt   # BPF programs loaded before benchmark
│       ├── bpftool.prog.after.txt    # BPF programs loaded after benchmark
│       ├── bpftool.map.before.txt    # BPF maps before/after
│       ├── bpftool.map.after.txt
│       ├── bpftool.link.before.txt   # BPF links before/after
│       ├── bpftool.link.after.txt
│       ├── bpftool.net.before.txt    # BPF network attachments before/after
│       ├── bpftool.net.after.txt
│       │
│       ├── softirqs.before.txt       # /proc/softirqs snapshot before benchmark
│       ├── softirqs.after.txt        # /proc/softirqs snapshot after benchmark
│       ├── interrupts.before.txt     # /proc/interrupts before/after
│       ├── interrupts.after.txt
│       │
│       ├── samples.csv               # time-series: timestamp, NET_RX_total, NET_TX_total
│       ├── meta.env                  # node, nic, kernel, perf binary path, exit codes
│       └── files.txt                 # index of all captured files
│
└── ringbuf_benchmark/
    └── <RUN_ID>_summary.txt          # baseline_gbps, with_retina_gbps, overhead_pct
```

### Useful one-liners after a run

```bash
# Show benchmark result for the latest run
tail -5 results/ringbuf_capture/ringbuf_benchmark/$(ls -t results/ringbuf_capture/ringbuf_benchmark/ | head -1)

# Show what perf actually captured
cat results/ringbuf_capture/<RUN_ID>_capture/pod_capture_*/perf.record.err.txt

# Check softirq delta (NET_RX before vs after)
diff results/ringbuf_capture/<RUN_ID>_capture/pod_capture_*/softirqs.before.txt \
     results/ringbuf_capture/<RUN_ID>_capture/pod_capture_*/softirqs.after.txt

# Open flamegraph on WSL
explorer.exe "$(wslpath -w results/ringbuf_capture/<RUN_ID>_capture/pod_capture_*/flamegraph.svg)"
```

---

## Viewing the Flamegraph

### On WSL (Windows Subsystem for Linux)

```bash
# Find the latest flamegraph
FG=$(find results/ringbuf_capture -name flamegraph.svg | sort | tail -1)
echo "$FG"

# Open in the default Windows browser
explorer.exe "$(wslpath -w "$FG")"
```

If `explorer.exe` opens the wrong app, copy the path it prints
(`\\wsl.localhost\Ubuntu\home\...`) and paste it into the Chrome or Edge
address bar directly.

### On Linux with a desktop

```bash
FG=$(find results/ringbuf_capture -name flamegraph.svg | sort | tail -1)
xdg-open "$FG"
# or: firefox "$FG" / google-chrome "$FG"
```

### Remote machine / no browser

Serve the SVG over HTTP for 60 seconds:

```bash
FG=$(find results/ringbuf_capture -name flamegraph.svg | sort | tail -1)
DIR=$(dirname "$FG")
cd "$DIR" && python3 -m http.server 8080
# then open http://<machine-ip>:8080/flamegraph.svg in any browser
```

---

## Reading the Flamegraph

The flamegraph from run `20260625T161002Z`:

```
results/ringbuf_capture/20260625T161002Z_capture/pod_capture_20260625T161045Z/flamegraph.svg
```

### Controls

| Action | Effect |
|---|---|
| **Hover** over a frame | Shows function name, binary, and % of total CPU samples |
| **Click** a frame | Zooms into that call subtree |
| **Ctrl+F** | Search by function name — highlights all matching frames |
| Click **Reset** (top-left) | Returns to the full-system view |
| Click **All** (top-left) | Shows all threads |

### What to look for (network receiver profiling)

| Frame | What it means |
|---|---|
| `do_softirq` / `net_rx_action` | Time in kernel network receive path |
| `tcp_recvmsg` / `tcp_v4_rcv` | TCP receive processing |
| `__sys_recvfrom` / `syscall_64` | User-space → kernel boundary for receive calls |
| `runtime.gcBgMarkWorker` | Go GC background work — watch for unexpected spikes |
| `runtime.mallocgc` | Memory allocation — allocation pressure indicator |
| Retina-related frames (`retina`, `packetparser`) | Retina plugin CPU cost |

**Wide frames = more CPU time.** A frame spanning 10% of the width means
10% of all CPU samples on all cores fell inside that function and its callees.

### Re-generating the flamegraph with different settings

If you want to filter by process or adjust colours:

```bash
cd results/ringbuf_capture/<RUN_ID>_capture/pod_capture_<TS>/

# Kernel-only flamegraph (strips user-space frames)
grep ' \[kernel\]' perf.script.txt | stackcollapse-perf.pl > kernel.folded.txt
flamegraph.pl --title "Kernel only" kernel.folded.txt > flamegraph-kernel.svg

# Filter to a specific process
grep '^iperf3\b\|^perf\b' perf.script.txt | stackcollapse-perf.pl > proc.folded.txt
flamegraph.pl proc.folded.txt > flamegraph-proc.svg

# Download scripts locally if not present
curl -fsSL https://raw.githubusercontent.com/brendangregg/FlameGraph/master/stackcollapse-perf.pl -o stackcollapse-perf.pl
curl -fsSL https://raw.githubusercontent.com/brendangregg/FlameGraph/master/flamegraph.pl -o flamegraph.pl
chmod +x stackcollapse-perf.pl flamegraph.pl
./stackcollapse-perf.pl < perf.script.txt | ./flamegraph.pl > flamegraph-custom.svg
```

---

## Benchmark Results (2026-06-25)

**Setup:** 4 client pods × 8 connections = 32 concurrent TCP streams.
10 s per phase. Node `aks-usr32-25342902-vmss000000` (Standard_D32s_v3, 32 vCPU).
Retina `packetParserRingBuffer: enabled`.

| Run ID | Baseline (Gbps) | With Retina (Gbps) | Overhead |
|---|---|---|---|
| 20260625T141655Z | 14.92 | 15.10 | −1.2% |
| 20260625T142542Z | 15.04 | 15.33 | −1.9% |
| 20260625T144428Z | 15.27 | 14.84 | +2.8% |
| 20260625T145013Z | 15.52 | 15.45 | +0.5% |
| 20260625T145456Z | 15.33 | 15.45 | −0.8% |
| 20260625T145911Z | 15.24 | 15.01 | +1.5% |
| 20260625T150744Z | 15.38 | 15.35 | +0.2% |
| 20260625T151833Z | 15.41 | 14.95 | +2.9% |
| 20260625T152543Z | 14.81 | 15.37 | −3.8% |
| 20260625T153110Z | 15.00 | 15.02 | −0.1% |
| 20260625T154638Z | 15.26 | 15.49 | −1.5% |
| 20260625T155655Z | 14.98 | 15.34 | −2.4% |
| 20260625T160104Z | 14.79 | 15.32 | −3.6% |
| 20260625T161004Z | 14.87 | 15.27 | −2.7% |

**Flamegraph run:** `20260625T161002Z` (perf exit 0, 95 057 samples, 13.4 MB perf.data)

**Summary:** Retina ring buffer overhead is within run-to-run measurement noise (±3–4%).
No statistically significant throughput degradation was observed at 32 concurrent
connections on a Standard_D32s_v3 node.

---

## Known Issues & Workarounds

### AKS control-plane API timeouts

The AKS API server (`20.252.67.117:443`) periodically drops connections for
30 s. This breaks `kubectl apply` (which does a GET before patching) and
`kubectl create` with schema validation (which downloads OpenAPI).

**Mitigations in place:**

```bash
# In run_reuseport_ab.sh: delete-then-create instead of apply
kubectl delete <resource> --ignore-not-found
kubectl create -f <manifest>     # no GET, no schema fetch

# In run_ringbuf_capture.sh: skip OpenAPI validation + retry loop
for attempt in 1 2 3; do
  kubectl create --validate=false -f capture-pod.yaml && break
  sleep 3
done
```

### `perf` inside a container — why chroot is needed

`perf` is statically linked to a specific glibc version matching the host
kernel's build. Inside a container:

| Approach | Why it fails |
|---|---|
| `apt-get install linux-tools-generic` in Ubuntu 24.04 | Pulls `linux-tools-6.x` — wrong kernel version |
| `apt-get install linux-tools-$(uname -r)` | The `linux-azure-tools-5.15.0-1114` package is not in Ubuntu 24.04 repos |
| Mount `/usr/lib/linux-tools` only | Symlinks inside point to `../../linux-azure-tools-*/perf` — broken relative path |
| Mount full host `/usr/lib` | perf binary resolves, but still can't find host glibc for dynamic linking |

**Solution:** Mount the entire host root at `/host-root` (writable) and run:
```bash
chroot /host-root /usr/lib/linux-tools/5.15.0-1114-azure/perf record ...
```
All libraries, the kernel symbol table, and `/tmp` (for perf.data output) are
now on the same filesystem that perf expects.

The host root mount must be **writable** because `perf record` writes the
output file to host `/tmp`. With a read-only mount, perf fails with
`Read-only file system`.

### FlameGraph tools not in apt

The `flamegraph` apt package does not exist. Scripts are fetched directly from
[brendangregg/FlameGraph](https://github.com/brendangregg/FlameGraph) at pod
startup via `curl` (falling back to `wget`). Internet access from the pod is
required.

### `kubectl cp` timing window

`kubectl cp` requires the pod to be running — it cannot exec into a completed
pod. The capture script keeps the pod alive for 180 s after the capture
completes (`sleep 180`) to give the wrapper time to copy artifacts out.

The wrapper runs `kubectl cp` after `--capture-duration + 20` seconds of
sleeping (inside a background subshell), timed to hit the pod while it is
still alive.
