#!/bin/bash
# cc_latency_bench.sh — Claude Code Tool Call Latency Bench
#
# Measures latency of Claude Code tool calls across different operations.
# Runs cold (single-shot) and warm (repeated) iterations, collects stats,
# and outputs a summary table plus CSV for further analysis.
#
# Usage: ./cc_latency_bench.sh [iterations] [label]
#   iterations  Number of warm iterations (default: 3)
#   label       Optional label for this benchmark run

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────
ITERATIONS=${1:-3}
LABEL=${2:-""}
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOSTNAME_SHORT=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results/${HOSTNAME_SHORT}_${TIMESTAMP}"
CSV_FILE="${RESULTS_DIR}/results.csv"
LOG_FILE="${RESULTS_DIR}/bench.log"
TEMP_DIR=""
CURRENT_MODE=""
CURRENT_ITER=0
COLD_ITERATIONS=1
NETWORK_ITERATIONS=3

declare -a TEST_NAMES=()

mkdir -p "$RESULTS_DIR"

# ─── Platform detection ──────────────────────────────────────────────
PLATFORM="unknown"
case "$(uname -s)" in
    Darwin)              PLATFORM="macos" ;;
    Linux)               PLATFORM="linux" ;;
    MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
esac

# ─── Logging ─────────────────────────────────────────────────────────
log_info() {
    local msg="[INFO] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

# ─── Cross-platform sed -i ───────────────────────────────────────────
sed_inplace() {
    if [[ "$PLATFORM" == "macos" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# ─── High-resolution timestamp (nanoseconds) ─────────────────────────
# Priority: EPOCHREALTIME (bash 5.0+ builtin, zero overhead)
#         > date +%s%N     (GNU date — Linux, Git Bash on Windows)
#         > gdate +%s%N    (GNU coreutils on macOS via Homebrew)
#         > perl HiRes     (preinstalled on macOS & most Linux, ~5ms)
#         > python3        (universal fallback, ~30ms — last resort)
TIMER_SOURCE=""

if [[ -n "${EPOCHREALTIME:-}" ]]; then
    # Bash 5.0+ built-in — microsecond precision, no subprocess
    timestamp_ns() {
        local t="$EPOCHREALTIME"
        local sec="${t%.*}"
        local frac="${t#*.}"
        echo "${sec}${frac}000"
    }
    TIMER_SOURCE="EPOCHREALTIME (bash builtin)"
elif date +%s%N 2>/dev/null | grep -qv 'N' 2>/dev/null; then
    # GNU date with nanosecond support (Linux, Git Bash/MSYS on Windows)
    timestamp_ns() { date +%s%N; }
    TIMER_SOURCE="date +%s%N"
elif command -v gdate &>/dev/null; then
    # GNU coreutils on macOS (brew install coreutils)
    timestamp_ns() { gdate +%s%N; }
    TIMER_SOURCE="gdate +%s%N"
elif perl -MTime::HiRes -e '1' 2>/dev/null; then
    # Perl Time::HiRes — preinstalled on macOS, fast startup
    timestamp_ns() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1e9'; }
    TIMER_SOURCE="perl Time::HiRes"
else
    # Python fallback — works everywhere, but ~30ms overhead per call
    timestamp_ns() { python3 -c "import time; print(int(time.time()*1e9))"; }
    TIMER_SOURCE="python3 (fallback)"
fi

# ─── Collect System Information ──────────────────────────────────────
collect_system_info() {
    local os_version cpu memory_gb shell_ver claude_ver node_ver

    case "$PLATFORM" in
        macos)
            os_version=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
            cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")
            local mem_bytes
            mem_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
            memory_gb=$(( mem_bytes / 1073741824 ))
            ;;
        linux)
            os_version=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || uname -r || echo "unknown")
            cpu=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "unknown")
            local mem_kb
            mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
            memory_gb=$(( mem_kb / 1048576 ))
            ;;
        windows)
            os_version=$(cmd.exe /c ver 2>/dev/null | tr -d '\r' | grep -i windows || uname -r || echo "unknown")
            cpu=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || \
                  wmic cpu get name 2>/dev/null | sed -n '2p' | xargs || echo "unknown")
            local mem_bytes
            mem_bytes=$(awk '/MemTotal/ {print $2 * 1024}' /proc/meminfo 2>/dev/null || echo 0)
            memory_gb=$(( mem_bytes / 1073741824 ))
            ;;
        *)
            os_version=$(uname -r || echo "unknown")
            cpu="unknown"
            memory_gb=0
            ;;
    esac

    shell_ver=$($SHELL --version 2>/dev/null | head -1 || echo "unknown")
    claude_ver=$(claude --version 2>/dev/null || echo "unknown")
    node_ver=$(node --version 2>/dev/null || echo "unknown")

    log_info "Platform: $PLATFORM"
    log_info "OS: $os_version"
    log_info "CPU: $cpu"
    log_info "Memory: ${memory_gb}GB"
    log_info "Shell: $shell_ver"
    log_info "Claude: $claude_ver"
    log_info "Node: $node_ver"
    log_info "Timer: $TIMER_SOURCE"
    log_info "Date: $(date)"
    log_info "Iterations: $ITERATIONS"
    [[ -n "$LABEL" ]] && log_info "Label: $LABEL"

    cat > "${RESULTS_DIR}/system_info.json" <<EOF
{
  "platform": "${PLATFORM}",
  "os": "${os_version}",
  "cpu": "${cpu}",
  "memory_gb": ${memory_gb},
  "shell": "$(echo "$shell_ver" | sed 's/"/\\"/g')",
  "claude_version": "$(echo "$claude_ver" | sed 's/"/\\"/g')",
  "node_version": "${node_ver}",
  "timer": "${TIMER_SOURCE}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)",
  "iterations": ${ITERATIONS},
  "label": "${LABEL}"
}
EOF
}

# ─── CSV ─────────────────────────────────────────────────────────────
init_csv() {
    echo "test_name,iteration,mode,duration_ms,output_bytes,ttfb_ms" > "$CSV_FILE"
}

log_to_csv() {
    echo "${1},${2},${3},${4},${5:-0},${6:-}" >> "$CSV_FILE"
}

# ─── Setup Temp Git Repo ────────────────────────────────────────────
setup_temp_repo() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cc_bench_XXXXXX")
    log_info "Temp repo: $TEMP_DIR"

    cd "$TEMP_DIR"
    git init -q
    git config user.email "bench@localhost"
    git config user.name "Benchmark"

    # ── Commit 1: Initial project structure ──────────────────────────
    mkdir -p src tests docs

    cat > src/main.py <<'PYEOF'
import sys
from src.utils import load_data, format_output
from src.models import DataProcessor

def main():
    """Main entry point for the application."""
    data = load_data("data/items.json")
    processor = DataProcessor(threshold=100)
    results = processor.process_all(data)
    print(format_output(results))
    return 0

if __name__ == "__main__":
    sys.exit(main())
PYEOF

    cat > src/utils.py <<'PYEOF'
import json
import os

def load_data(path):
    """Load and return data items from a JSON file."""
    full_path = os.path.join(os.path.dirname(__file__), "..", path)
    if os.path.exists(full_path):
        with open(full_path) as f:
            return json.load(f)
    return []

def format_output(items):
    """Format processed items for display."""
    lines = []
    for item in items:
        lines.append(f"  {item['name']}: {item['original']} -> {item['processed']}")
    return "\n".join(lines)

def validate_item(item):
    """Validate a single data item has required fields."""
    required = ("value", "name")
    return all(k in item for k in required)
PYEOF

    cat > src/models.py <<'PYEOF'
class DataProcessor:
    """Processes data items with configurable threshold."""

    def __init__(self, threshold=100):
        self.threshold = threshold
        self._cache = {}

    def process_item(self, item):
        value = item.get("value", 0)
        name = item.get("name", "unknown")
        result = value * 2
        if result > self.threshold:
            self._cache[name] = result
        return {"name": name, "original": value, "processed": result}

    def process_all(self, data):
        return [self.process_item(item) for item in data]

    def get_cached(self):
        return dict(self._cache)
PYEOF

    cat > src/handlers.py <<'PYEOF'
import logging

logger = logging.getLogger(__name__)

class RequestHandler:
    def __init__(self, processor):
        self.processor = processor

    def handle(self, request):
        logger.info(f"Processing request: {request.get('id', 'unknown')}")
        data = request.get("items", [])
        results = self.processor.process_all(data)
        return {"status": "ok", "results": results, "count": len(results)}

    def handle_batch(self, requests):
        return [self.handle(r) for r in requests]
PYEOF

    cat > src/config.py <<'PYEOF'
import os

DEFAULTS = {
    "threshold": 100,
    "batch_size": 50,
    "log_level": "INFO",
    "output_format": "text",
    "max_retries": 3,
}

def get_config():
    config = dict(DEFAULTS)
    for key in DEFAULTS:
        env_val = os.environ.get(f"APP_{key.upper()}")
        if env_val is not None:
            config[key] = type(DEFAULTS[key])(env_val)
    return config
PYEOF

    touch src/__init__.py

    cat > tests/test_main.py <<'PYEOF'
import unittest
from src.models import DataProcessor

class TestDataProcessor(unittest.TestCase):
    def setUp(self):
        self.processor = DataProcessor(threshold=50)

    def test_process_item_basic(self):
        result = self.processor.process_item({"value": 10, "name": "test"})
        self.assertEqual(result["processed"], 20)

    def test_process_item_threshold(self):
        self.processor.process_item({"value": 30, "name": "high"})
        self.assertIn("high", self.processor.get_cached())

    def test_process_all(self):
        data = [{"value": i, "name": f"item_{i}"} for i in range(5)]
        results = self.processor.process_all(data)
        self.assertEqual(len(results), 5)

if __name__ == "__main__":
    unittest.main()
PYEOF

    cat > tests/test_utils.py <<'PYEOF'
import unittest
from src.utils import validate_item

class TestUtils(unittest.TestCase):
    def test_validate_valid(self):
        self.assertTrue(validate_item({"value": 1, "name": "a"}))

    def test_validate_missing_field(self):
        self.assertFalse(validate_item({"value": 1}))

if __name__ == "__main__":
    unittest.main()
PYEOF

    mkdir -p data
    cat > data/items.json <<'JSONEOF'
[
  {"value": 10, "name": "alpha"},
  {"value": 20, "name": "beta"},
  {"value": 30, "name": "gamma"},
  {"value": 40, "name": "delta"},
  {"value": 50, "name": "epsilon"},
  {"value": 60, "name": "zeta"},
  {"value": 70, "name": "eta"},
  {"value": 80, "name": "theta"}
]
JSONEOF

    cat > README.md <<'MDEOF'
# Test Project

A data processing application for benchmarking.

## Setup
```bash
pip install -r requirements.txt
python -m src.main
```

## Testing
```bash
python -m pytest tests/
```
MDEOF

    cat > requirements.txt <<'EOF'
pytest>=7.0
black>=23.0
mypy>=1.0
EOF

    cat > .gitignore <<'EOF'
__pycache__/
*.pyc
.env
.venv/
dist/
*.egg-info/
EOF

    # Generate additional source files
    for i in $(seq 1 20); do
        cat > "src/module_${i}.py" <<PYEOF
"""Module ${i} — auto-generated for benchmark testing."""

def compute_${i}(x):
    """Compute transformation ${i}."""
    return x * ${i} + ${i}

def validate_${i}(data):
    """Validate input for module ${i}."""
    if not isinstance(data, (int, float)):
        raise TypeError(f"Expected number, got {type(data)}")
    return data >= 0

class Worker${i}:
    def __init__(self):
        self.count = 0
    def run(self, value):
        self.count += 1
        return compute_${i}(value)
PYEOF
    done

    # Large file for read benchmarks
    for i in $(seq 1 200); do
        echo "Line $i: Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam." >> large_file.txt
    done

    git add -A
    git commit -q -m "Initial project structure with 20 modules"

    # ── Commit 2: Feature additions ──────────────────────────────────
    cat >> src/utils.py <<'PYEOF'

def merge_results(results_a, results_b):
    """Merge two result lists, deduplicating by name."""
    seen = set()
    merged = []
    for item in results_a + results_b:
        if item["name"] not in seen:
            seen.add(item["name"])
            merged.append(item)
    return merged
PYEOF

    cat > src/analytics.py <<'PYEOF'
"""Analytics module for computing statistics over processed data."""
import math

def mean(values):
    return sum(values) / len(values) if values else 0

def stddev(values):
    if len(values) < 2:
        return 0
    m = mean(values)
    variance = sum((x - m) ** 2 for x in values) / (len(values) - 1)
    return math.sqrt(variance)

def summary(data):
    values = [d["processed"] for d in data]
    return {"mean": mean(values), "stddev": stddev(values),
            "min": min(values), "max": max(values), "count": len(values)}
PYEOF

    git add -A
    git commit -q -m "Add analytics module and merge_results utility"

    # ── Commit 3: Bug fix ────────────────────────────────────────────
    sed_inplace 's/return x \* ${i}/return x * 2/' src/module_1.py 2>/dev/null || true

    cat > docs/CHANGELOG.md <<'MDEOF'
# Changelog

## v0.3.0
- Fixed computation in module_1
- Added analytics module

## v0.2.0
- Added merge_results utility
- Extended data items

## v0.1.0
- Initial release
MDEOF

    git add -A
    git commit -q -m "Fix module_1 computation bug, add changelog"

    # Leave an uncommitted change so git status/diff have output
    echo "# TODO: add caching layer" >> src/models.py

    cd - >/dev/null
    log_info "Repo ready: 30+ files, 3 commits, 1 uncommitted change"
}

# ─── Cleanup ─────────────────────────────────────────────────────────
cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR:-}" ]]; then
        rm -rf "$TEMP_DIR"
        log_info "Cleaned up: $TEMP_DIR"
    fi
}
trap cleanup EXIT

# ─── Core Benchmark Runner ──────────────────────────────────────────
run_cc_test() {
    local test_name="$1"; shift

    # Track unique test names in order
    local already=0
    for t in "${TEST_NAMES[@]+"${TEST_NAMES[@]}"}"; do
        [[ "$t" == "$test_name" ]] && already=1 && break
    done
    (( already )) || TEST_NAMES+=("$test_name")

    local start_ns end_ns duration_ms output output_bytes

    start_ns=$(timestamp_ns)
    output=$("$@" 2>&1) || true
    end_ns=$(timestamp_ns)

    duration_ms=$(awk "BEGIN {printf \"%.1f\", ($end_ns - $start_ns) / 1000000}")

    output_bytes=$(echo -n "$output" | wc -c | tr -d ' ')

    log_to_csv "$test_name" "$CURRENT_ITER" "$CURRENT_MODE" "$duration_ms" "$output_bytes" ""
    printf "    %-20s %8sms  (%s bytes)\n" "$test_name" "$duration_ms" "$output_bytes"
}

# ─── Test Suite ─────────────────────────────────────────────────────
run_all_tests() {
    # Reset working tree so each iteration starts clean
    git checkout -- . 2>/dev/null || true
    echo "# TODO: add caching layer" >> src/models.py

    # 1. Shell command init — baseline shell spawn
    run_cc_test "shell_cmd_init" \
        bash -c "echo hello world"

    # 2. File open/read — read a source file
    run_cc_test "shell_open" \
        cat src/main.py

    # 3. Shell spawn — cat large file through bash
    run_cc_test "shell_spawn" \
        bash -c "cat large_file.txt"

    # 4. Stdout capture — git status output
    run_cc_test "stdout_capture" \
        git status --short

    # 5. Shell exec init — python interpreter startup
    run_cc_test "shell_exec_init" \
        python3 -c "print(sum(range(100)))"

    # 6. File edit — sed in-place edit
    run_cc_test "file_edit" \
        sed_inplace '1s/^/# Benchmarked\n/' src/utils.py

    # 7. Git log — commit history
    run_cc_test "git_log_init" \
        git log --oneline

    # 8. Git diff — diff against last commit
    run_cc_test "git_diff" \
        git diff HEAD

    # 9. Grep search — search across repo
    run_cc_test "lookup_capture" \
        grep -rn "def " --include="*.py" .

    # 10. Tool lookup — find files by pattern
    run_cc_test "tool_lookup" \
        find . -name "*.py" -type f
}

# ─── Network Latency ────────────────────────────────────────────────
run_network_test() {
    local test_name="network_rtt"

    local already=0
    for t in "${TEST_NAMES[@]+"${TEST_NAMES[@]}"}"; do
        [[ "$t" == "$test_name" ]] && already=1 && break
    done
    (( already )) || TEST_NAMES+=("$test_name")

    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        log_info "Skipping network_rtt (ANTHROPIC_API_KEY not set)"
        return
    fi

    local start_ns end_ns duration_ms curl_timings ttfb_ms

    start_ns=$(timestamp_ns)

    curl_timings=$(curl -s -o /dev/null \
        -w "dns=%{time_namelookup} tcp=%{time_connect} ssl=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total}" \
        --connect-timeout 30 \
        -X POST "https://api.anthropic.com/v1/messages" \
        -H "Content-Type: application/json" \
        -H "x-api-key: ${ANTHROPIC_API_KEY}" \
        -H "anthropic-version: 2023-06-01" \
        -d '{"model":"claude-sonnet-4-20250514","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}') || true

    end_ns=$(timestamp_ns)

    duration_ms=$(awk "BEGIN {printf \"%.1f\", ($end_ns - $start_ns) / 1000000}")

    ttfb_ms=""
    if [[ "$curl_timings" =~ ttfb=([0-9.]+) ]]; then
        ttfb_ms=$(awk "BEGIN {printf \"%.1f\", ${BASH_REMATCH[1]} * 1000}")
    fi

    log_to_csv "$test_name" "$CURRENT_ITER" "$CURRENT_MODE" "$duration_ms" "0" "$ttfb_ms"
    printf "    %-20s %8sms  (ttfb=%sms) [%s]\n" "$test_name" "$duration_ms" "$ttfb_ms" "$curl_timings"
}

# ─── Statistics ──────────────────────────────────────────────────────
compute_stats() {
    local test_name="$1" mode="$2"
    awk -F',' -v name="$test_name" -v m="$mode" '
    NR > 1 && $1 == name && $3 == m && $4 != "" {
        v = $4 + 0; n++; sum += v; sumsq += v * v
        if (n == 1 || v < min) min = v
        if (n == 1 || v > max) max = v
    }
    END {
        if (n > 0) {
            mean = sum / n
            if (n > 1) { var = (sumsq - sum*sum/n)/(n-1); sd = sqrt(var>0?var:0) }
            else sd = 0
            printf "%7.1f %7.1f %7.1f %7.1f", min, mean, max, sd
        } else {
            printf "%7s %7s %7s %7s", "  N/A", "  N/A", "  N/A", "  N/A"
        }
    }' "$CSV_FILE"
}

print_summary_statistics() {
    echo ""
    echo "════════════════════════════════════════════════════════════════════════════════════════════"
    echo "                                   BENCHMARK SUMMARY"
    echo "════════════════════════════════════════════════════════════════════════════════════════════"
    printf "%-20s │ %-31s │ %-31s\n" "" "          Cold (ms)" "          Warm (ms)"
    printf "%-20s │ %7s %7s %7s %7s │ %7s %7s %7s %7s\n" \
        "Test" "Min" "Mean" "Max" "StdDev" "Min" "Mean" "Max" "StdDev"
    echo "─────────────────────┼─────────────────────────────────┼─────────────────────────────────"

    for test_name in "${TEST_NAMES[@]}"; do
        local cold warm
        cold=$(compute_stats "$test_name" "cold")
        warm=$(compute_stats "$test_name" "warm")
        printf "%-20s │ %s │ %s\n" "$test_name" "$cold" "$warm"
    done

    echo "════════════════════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "Results CSV: $CSV_FILE"
    echo "Log file:    $LOG_FILE"
}

# ─── HTML Report ─────────────────────────────────────────────────────
generate_html_report() {
    local html_file="${RESULTS_DIR}/report.html"

    cat > "$html_file" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Claude Code Latency Bench</title>
<style>
  body { font-family: system-ui, -apple-system, monospace; margin: 2rem; background: #0d1117; color: #c9d1d9; }
  h1 { color: #58a6ff; border-bottom: 1px solid #30363d; padding-bottom: .5rem; }
  h2 { color: #8b949e; }
  table { border-collapse: collapse; width: 100%; margin: 1rem 0; }
  th, td { padding: 6px 12px; border: 1px solid #30363d; text-align: right; }
  th { background: #161b22; color: #58a6ff; }
  td:first-child { text-align: left; font-weight: 600; }
  tr:nth-child(even) { background: #161b22; }
  .meta { color: #8b949e; font-size: .85em; margin-bottom: 1.5rem; }
  .cold { color: #79c0ff; }
  .warm { color: #56d364; }
</style>
</head>
<body>
<h1>Claude Code Tool Call Latency Bench</h1>
<div class="meta" id="meta"></div>
<h2>Results</h2>
<div id="tbl"></div>
<script>
HTMLEOF

    # Embed data
    echo "const csv = \`" >> "$html_file"
    cat "$CSV_FILE" >> "$html_file"
    echo "\`;" >> "$html_file"
    echo "const sysinfo = $(cat "${RESULTS_DIR}/system_info.json");" >> "$html_file"

    cat >> "$html_file" <<'HTMLEOF2'
const rows = csv.trim().split('\n').slice(1).map(r => {
  const c = r.split(',');
  return { test: c[0], iter: +c[1], mode: c[2], dur: +c[3], bytes: +c[4] };
});
document.getElementById('meta').innerHTML =
  `${sysinfo.timestamp} &middot; OS ${sysinfo.os} &middot; ${sysinfo.cpu} &middot; ${sysinfo.memory_gb}GB RAM<br>` +
  `Claude ${sysinfo.claude_version} &middot; Node ${sysinfo.node_version} &middot; ${sysinfo.iterations} warm iterations`;

const tests = [...new Set(rows.map(r => r.test))];
function stats(t, m) {
  const v = rows.filter(r => r.test===t && r.mode===m).map(r => r.dur);
  if (!v.length) return { min:'N/A', mean:'N/A', max:'N/A', sd:'N/A' };
  const n = v.length, s = v.reduce((a,b) => a+b, 0), mn = s/n;
  const sd = n > 1 ? Math.sqrt(v.reduce((a,x) => a+(x-mn)**2, 0)/(n-1)) : 0;
  const f = x => typeof x === 'number' ? x.toFixed(1) : x;
  return { min: f(Math.min(...v)), mean: f(mn), max: f(Math.max(...v)), sd: f(sd) };
}

let h = '<table>';
h += '<tr><th rowspan=2>Test</th><th colspan=4 class="cold">Cold (ms)</th><th colspan=4 class="warm">Warm (ms)</th></tr>';
h += '<tr><th>Min</th><th>Mean</th><th>Max</th><th>StdDev</th><th>Min</th><th>Mean</th><th>Max</th><th>StdDev</th></tr>';
tests.forEach(t => {
  const c = stats(t, 'cold'), w = stats(t, 'warm');
  h += `<tr><td>${t}</td>` +
    `<td>${c.min}</td><td>${c.mean}</td><td>${c.max}</td><td>${c.sd}</td>` +
    `<td>${w.min}</td><td>${w.mean}</td><td>${w.max}</td><td>${w.sd}</td></tr>`;
});
h += '</table>';
document.getElementById('tbl').innerHTML = h;
</script>
</body>
</html>
HTMLEOF2

    local sz
    sz=$(wc -c < "$html_file" | tr -d ' ')
    log_info "Output HTML: $html_file"
    log_info "HTML report generated: $html_file"
    log_info "Size: ${sz} bytes"
}

# ═══ MAIN ════════════════════════════════════════════════════════════
main() {
    echo ""
    echo "───────────────────────────────────────────────"
    echo "  Claude Code Tool Call Latency Bench"
    echo "───────────────────────────────────────────────"
    echo ""

    # Check prerequisites
    for cmd in claude git awk; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "ERROR: Required command '$cmd' not found" >&2
            exit 1
        fi
    done

    # Phase 1
    echo "Phase 1: Collecting system information..."
    collect_system_info
    echo ""

    # Phase 2
    echo "Phase 2: Initializing results..."
    init_csv
    echo ""

    # Phase 3
    echo "Phase 3: Setting up temp git repo..."
    setup_temp_repo
    echo "  Repo at: $TEMP_DIR"
    echo ""

    # Phase 4 — Cold tests
    echo "Phase 4: Running COLD tests (${COLD_ITERATIONS} iteration each, ${NETWORK_ITERATIONS} for network)..."
    CURRENT_MODE="cold"
    for ((i = 1; i <= COLD_ITERATIONS; i++)); do
        CURRENT_ITER=$i
        log_info "Iteration ${i}/${COLD_ITERATIONS}:"
        cd "$TEMP_DIR"
        run_all_tests
        cd - >/dev/null
    done
    for ((i = 1; i <= NETWORK_ITERATIONS; i++)); do
        CURRENT_ITER=$i
        run_network_test
    done
    echo ""

    # Phase 5 — Warm tests
    echo "Phase 5: Running WARM tests (${ITERATIONS} iterations each)..."
    CURRENT_MODE="warm"
    for ((i = 1; i <= ITERATIONS; i++)); do
        CURRENT_ITER=$i
        log_info "Iteration ${i}/${ITERATIONS}:"
        cd "$TEMP_DIR"
        run_all_tests
        cd - >/dev/null
        run_network_test
    done
    echo ""

    # Phase 6
    echo "Phase 6: Cleaning up temp repo..."
    # cleanup handled by EXIT trap
    echo ""

    # Summary
    print_summary_statistics

    # HTML Report
    generate_html_report

    echo ""
    echo "BENCHMARK_${TIMESTAMP}"
}

main
