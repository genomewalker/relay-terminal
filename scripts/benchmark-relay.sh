#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
sample_seconds="${RELAY_BENCHMARK_SECONDS:-30}"
app_path="${RELAY_BENCHMARK_APP:-/Applications/Relay.app}"
output_dir="${RELAY_BENCHMARK_OUTPUT:-$project_dir/benchmark-results}"
mkdir -p "$output_dir"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
protocol_output="$output_dir/protocol-$timestamp.txt"
idle_output="$output_dir/app-idle-$timestamp.tsv"
memory_start="$output_dir/memory-start-$timestamp.txt"
memory_end="$output_dir/memory-end-$timestamp.txt"
stacks_output="$output_dir/stacks-$timestamp.txt"

(cd "$project_dir/remote/relayd" && \
  go test ./internal/protocol -run '^$' -bench 'Benchmark(Frame|Host)' -benchmem -count 5) \
  | tee "$protocol_output"

pid="$(pgrep -x Relay | head -1 || true)"
started_app=0
if [[ -z "$pid" && -d "$app_path" ]]; then
  open -na "$app_path"
  started_app=1
  for _ in {1..50}; do
    pid="$(pgrep -x Relay | head -1 || true)"
    [[ -n "$pid" ]] && break
    sleep 0.1
  done
fi

printf 'utc\tpid\tcpu_percent\trss_kib\tthreads\n' > "$idle_output"
if [[ -n "$pid" ]]; then
  vmmap -summary "$pid" > "$memory_start" 2>&1 || true
  for ((sample=0; sample<sample_seconds; sample++)); do
    thread_count="$(ps -M -p "$pid" | awk 'NR > 1 { count += 1 } END { print count + 0 }')"
    ps -p "$pid" -o pid=,%cpu=,rss= | awk -v now="$(date -u +%FT%TZ)" -v threads="$thread_count" \
      '{print now "\t" $1 "\t" $2 "\t" $3 "\t" threads}' >> "$idle_output"
    sleep 1
  done
  vmmap -summary "$pid" > "$memory_end" 2>&1 || true
  sample "$pid" 2 1 > "$stacks_output" 2>&1 || true
else
  printf 'Relay is not running and %s was not found\n' "$app_path" >&2
fi

if [[ "$started_app" == 1 && "${RELAY_BENCHMARK_KEEP_APP:-0}" != 1 && -n "$pid" ]]; then
  osascript -e 'tell application "Relay" to quit' >/dev/null 2>&1 || true
fi

printf 'Protocol: %s\nIdle samples: %s\nMemory: %s and %s\nStacks: %s\n' \
  "$protocol_output" "$idle_output" "$memory_start" "$memory_end" "$stacks_output"
printf 'For Instruments Energy Log, run: xcrun xctrace record --template "Energy Log" --time-limit %ss --attach Relay --output "%s/energy-%s.trace"\n' \
  "$sample_seconds" "$output_dir" "$timestamp"
