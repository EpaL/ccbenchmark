#!/bin/bash
# generate_dashboard.sh — Comparison dashboard for cc_latency_bench results
#
# Scans all result folders under ./results/ and generates a single
# HTML dashboard comparing every machine/run side by side.
#
# Usage: ./generate_dashboard.sh [output_file]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_ROOT="${SCRIPT_DIR}/results"
OUTPUT_FILE="${1:-${SCRIPT_DIR}/comparison-dashboard.html}"

# ─── Discover result sets ────────────────────────────────────────────
declare -a RUN_DIRS=()
for dir in "${RESULTS_ROOT}"/*/; do
    [[ -f "${dir}results.csv" && -f "${dir}system_info.json" ]] && RUN_DIRS+=("$dir")
done

if [[ ${#RUN_DIRS[@]} -eq 0 ]]; then
    echo "ERROR: No result sets found in ${RESULTS_ROOT}/" >&2
    echo "       Run cc_latency_bench.sh first to generate results." >&2
    exit 1
fi

echo "[INFO] Found ${#RUN_DIRS[@]} result set(s):"
for d in "${RUN_DIRS[@]}"; do echo "  - $(basename "$d")"; done

# ─── Build embedded JSON data ────────────────────────────────────────
# Collect all runs into a single JSON array for the HTML to consume
DATA_JSON="["
first_run=1
for dir in "${RUN_DIRS[@]}"; do
    run_name=$(basename "$dir")
    sysinfo=$(cat "${dir}system_info.json")
    csv_content=$(cat "${dir}results.csv")

    [[ $first_run -eq 1 ]] && first_run=0 || DATA_JSON+=","
    # Escape backticks and backslashes in CSV for JS template literal
    csv_escaped=$(echo "$csv_content" | sed 's/\\/\\\\/g; s/`/\\`/g')

    DATA_JSON+=$(cat <<JEOF
{
  "name": "${run_name}",
  "sysinfo": ${sysinfo},
  "csv": \`${csv_escaped}\`
}
JEOF
)
done
DATA_JSON+="]"

# ─── Generate HTML ───────────────────────────────────────────────────
cat > "$OUTPUT_FILE" <<'HTML_HEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Claude Code Latency Bench — Comparison Dashboard</title>
<style>
:root {
  --bg: #0d1117; --bg2: #161b22; --border: #30363d;
  --fg: #c9d1d9; --fg2: #8b949e; --accent: #58a6ff;
  --green: #56d364; --red: #f85149; --yellow: #e3b341;
  --blue: #79c0ff; --purple: #bc8cff;
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Courier New", monospace; background: var(--bg); color: var(--fg); padding: 24px; }
h1 { color: var(--accent); font-size: 1.5rem; margin-bottom: 4px; }
.subtitle { color: var(--fg2); font-size: .85rem; margin-bottom: 24px; }
h2 { color: var(--fg); font-size: 1.1rem; margin: 24px 0 12px; border-bottom: 1px solid var(--border); padding-bottom: 6px; }
h3 { color: var(--fg2); font-size: .95rem; margin: 16px 0 8px; }

/* System info cards */
.cards { display: flex; flex-wrap: wrap; gap: 12px; margin-bottom: 16px; }
.card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 12px 16px; min-width: 280px; flex: 1; }
.card-title { color: var(--accent); font-weight: 600; font-size: .9rem; margin-bottom: 6px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.card-row { color: var(--fg2); font-size: .8rem; line-height: 1.6; }
.card-row span { color: var(--fg); }

/* Tables */
table { border-collapse: collapse; width: 100%; margin: 8px 0 20px; font-size: .85rem; }
th, td { padding: 6px 10px; border: 1px solid var(--border); text-align: right; white-space: nowrap; }
th { background: var(--bg2); color: var(--accent); position: sticky; top: 0; }
td:first-child, th:first-child { text-align: left; font-weight: 600; }
tr:nth-child(even) { background: var(--bg2); }

/* Color coding for comparison */
.best { color: var(--green); font-weight: 600; }
.worst { color: var(--red); }
.only { color: var(--fg2); }

/* Chart */
.chart-wrap { margin: 16px 0; overflow-x: auto; }
canvas { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; }

/* Legend */
.legend { display: flex; flex-wrap: wrap; gap: 16px; margin: 8px 0 16px; font-size: .8rem; color: var(--fg2); }
.legend-item { display: flex; align-items: center; gap: 4px; }
.legend-swatch { width: 14px; height: 14px; border-radius: 3px; }

/* Footer */
.footer { margin-top: 32px; padding-top: 12px; border-top: 1px solid var(--border); color: var(--fg2); font-size: .75rem; }
</style>
</head>
<body>
<h1>Claude Code Tool Call Latency Bench</h1>
<p class="subtitle">Comparison Dashboard</p>

<div id="app"></div>

<div class="footer">
  Generated <span id="gen-time"></span> &middot;
  <span id="run-count"></span> run(s) compared
</div>

<script>
HTML_HEAD

# Inject the data
echo "const RUNS = ${DATA_JSON};" >> "$OUTPUT_FILE"

cat >> "$OUTPUT_FILE" <<'HTML_JS'
// ─── Parse CSV rows ──────────────────────────────────────────────────
function parseCSV(csv) {
  const lines = csv.trim().split('\n');
  return lines.slice(1).map(line => {
    const c = line.split(',');
    return { test: c[0], iter: +c[1], mode: c[2], dur: +c[3], bytes: +c[4],
             ttfb: (c[5] && c[5] !== '') ? +c[5] : null };
  });
}

// ─── Compute stats for a given field ─────────────────────────────────
function stats(rows, testName, mode, field = 'dur') {
  const v = rows.filter(r => r.test === testName && r.mode === mode && r[field] != null)
               .map(r => r[field]);
  if (!v.length) return null;
  const n = v.length, s = v.reduce((a, b) => a + b, 0), mean = s / n;
  const min = Math.min(...v), max = Math.max(...v);
  const sd = n > 1 ? Math.sqrt(v.reduce((a, x) => a + (x - mean) ** 2, 0) / (n - 1)) : 0;
  return { min, mean, max, sd, n };
}

// ─── Helpers ─────────────────────────────────────────────────────────
const fmt = v => v == null ? 'N/A' : v.toFixed(1);
const fmtS = v => v == null ? 'N/A' : (v / 1000).toFixed(2) + 's';
const COLORS = ['#79c0ff', '#56d364', '#e3b341', '#bc8cff', '#f85149', '#ff7b72', '#79c0ff', '#d2a8ff'];

// ─── Process runs ────────────────────────────────────────────────────
const runs = RUNS.map((r, i) => ({
  ...r,
  rows: parseCSV(r.csv),
  color: COLORS[i % COLORS.length],
  shortName: r.name.replace(/_\d{8}_\d{6}$/, '')
}));

// Split tests into native and cc_ groups
const allTests = [...new Set(runs.flatMap(r => r.rows.map(row => row.test)))];
const nativeTests = allTests.filter(t => !t.startsWith('cc_'));
const ccTests = allTests.filter(t => t.startsWith('cc_'));

// ─── Build page ──────────────────────────────────────────────────────
const app = document.getElementById('app');
let html = '';

// System info cards
html += '<h2>Systems</h2><div class="cards">';
runs.forEach((r, i) => {
  const s = r.sysinfo;
  html += `<div class="card" style="border-top: 3px solid ${r.color}">
    <div class="card-title">${r.shortName}</div>
    <div class="card-row">Platform: <span>${s.platform}</span></div>
    <div class="card-row">OS: <span>${s.os}</span></div>
    <div class="card-row">CPU: <span>${s.cpu}</span></div>
    <div class="card-row">RAM: <span>${s.memory_gb}GB</span></div>
    <div class="card-row">Shell: <span>${s.shell}</span></div>
    <div class="card-row">Claude: <span>${s.claude_version}</span></div>
    <div class="card-row">Timer: <span>${s.timer}</span></div>
    <div class="card-row">Iterations: <span>${s.iterations}</span></div>
    <div class="card-row">Date: <span>${s.timestamp}</span></div>
  </div>`;
});
html += '</div>';

// Legend
html += '<div class="legend">';
runs.forEach(r => {
  html += `<div class="legend-item"><div class="legend-swatch" style="background:${r.color}"></div>${r.shortName}</div>`;
});
html += '</div>';

// ─── Helper: build a comparison table ────────────────────────────────
function buildTable(tests, mode, label, unit) {
  let t = `<h2>${label}</h2>`;
  t += '<table><tr><th>Test</th>';
  runs.forEach(r => {
    t += `<th colspan="4" style="color:${r.color}">${r.shortName}</th>`;
  });
  t += '</tr><tr><th></th>';
  runs.forEach(() => { t += `<th>Min</th><th>Mean</th><th>Max</th><th>SD</th>`; });
  t += '</tr>';

  tests.forEach(test => {
    const allS = runs.map(r => stats(r.rows, test, mode));
    const means = allS.map(s => s ? s.mean : Infinity);
    const bestIdx = means.indexOf(Math.min(...means));
    const worstIdx = means.indexOf(Math.max(...means.filter(m => m < Infinity)));

    t += `<tr><td>${test}</td>`;
    allS.forEach((s, i) => {
      if (!s) {
        t += '<td class="only">\u2014</td><td class="only">\u2014</td><td class="only">\u2014</td><td class="only">\u2014</td>';
      } else {
        const cls = runs.length > 1 ? (i === bestIdx ? 'best' : i === worstIdx ? 'worst' : '') : '';
        t += `<td class="${cls}">${fmt(s.min)}</td><td class="${cls}">${fmt(s.mean)}</td><td class="${cls}">${fmt(s.max)}</td><td class="${cls}">${fmt(s.sd)}</td>`;
      }
    });
    t += '</tr>';
  });
  t += '</table>';
  return t;
}

// ─── Native baseline tables ──────────────────────────────────────────
if (nativeTests.length) {
  html += buildTable(nativeTests, 'warm', 'Native Baseline — Warm (ms)', 'ms');
  html += buildTable(nativeTests, 'cold', 'Native Baseline — Cold (ms)', 'ms');
}

// ─── Claude Code E2E tables (duration + TTFB) ───────────────────────
if (ccTests.length) {
  // Duration table
  html += buildTable(ccTests, 'warm', 'Claude Code End-to-End — Warm Duration (ms)', 'ms');

  // TTFB table
  html += '<h2>Claude Code End-to-End — Warm TTFB (ms)</h2>';
  html += '<table><tr><th>Test</th>';
  runs.forEach(r => {
    html += `<th colspan="4" style="color:${r.color}">${r.shortName}</th>`;
  });
  html += '</tr><tr><th></th>';
  runs.forEach(() => { html += '<th>Min</th><th>Mean</th><th>Max</th><th>SD</th>'; });
  html += '</tr>';

  ccTests.forEach(test => {
    const allS = runs.map(r => stats(r.rows, test, 'warm', 'ttfb'));
    const means = allS.map(s => s ? s.mean : Infinity);
    const bestIdx = means.indexOf(Math.min(...means));
    const worstIdx = means.indexOf(Math.max(...means.filter(m => m < Infinity)));

    html += `<tr><td>${test}</td>`;
    allS.forEach((s, i) => {
      if (!s) {
        html += '<td class="only">\u2014</td><td class="only">\u2014</td><td class="only">\u2014</td><td class="only">\u2014</td>';
      } else {
        const cls = runs.length > 1 ? (i === bestIdx ? 'best' : i === worstIdx ? 'worst' : '') : '';
        html += `<td class="${cls}">${fmt(s.min)}</td><td class="${cls}">${fmt(s.mean)}</td><td class="${cls}">${fmt(s.max)}</td><td class="${cls}">${fmt(s.sd)}</td>`;
      }
    });
    html += '</tr>';
  });
  html += '</table>';
}

// ─── Bar charts (separate scales for native vs cc) ──────────────────
function drawChart(canvasId, tests, title) {
  html += `<h2>${title}</h2>`;
  html += `<div class="chart-wrap"><canvas id="${canvasId}"></canvas></div>`;
}

if (nativeTests.length) drawChart('chart-native', nativeTests, 'Native Baseline — Warm Mean Latency');
if (ccTests.length)     drawChart('chart-cc', ccTests, 'Claude Code E2E — Warm Mean Latency');

app.innerHTML = html;

// ─── Render a bar chart on a canvas ──────────────────────────────────
function renderChart(canvasId, tests) {
  const canvas = document.getElementById(canvasId);
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  const barH = 18, groupGap = 14, labelW = 150, rightPad = 90;
  const groupH = runs.length * barH + groupGap;
  canvas.width = Math.max(canvas.parentElement.offsetWidth - 4, 600);
  canvas.height = tests.length * groupH + 40;

  const maxMean = Math.max(...tests.flatMap(t =>
    runs.map(r => { const s = stats(r.rows, t, 'warm'); return s ? s.mean : 0; })
  ));
  const chartW = canvas.width - labelW - rightPad;

  tests.forEach((test, ti) => {
    const y0 = ti * groupH + 20;

    ctx.fillStyle = '#c9d1d9';
    ctx.font = '12px monospace';
    ctx.textAlign = 'right';
    ctx.textBaseline = 'middle';
    ctx.fillText(test, labelW - 8, y0 + (runs.length * barH) / 2);

    runs.forEach((r, ri) => {
      const s = stats(r.rows, test, 'warm');
      if (!s) return;
      const by = y0 + ri * barH;
      const bw = Math.max((s.mean / maxMean) * chartW, 2);

      ctx.fillStyle = r.color;
      ctx.globalAlpha = 0.85;
      ctx.fillRect(labelW, by, bw, barH - 2);
      ctx.globalAlpha = 1;

      // Value label — use seconds for cc_ tests if >1000ms
      const label = s.mean >= 1000 ? (s.mean/1000).toFixed(2) + 's' : s.mean.toFixed(1) + 'ms';
      ctx.fillStyle = '#c9d1d9';
      ctx.font = '11px monospace';
      ctx.textAlign = 'left';
      ctx.textBaseline = 'middle';
      ctx.fillText(label, labelW + bw + 4, by + barH / 2);
    });
  });
}

if (nativeTests.length) renderChart('chart-native', nativeTests);
if (ccTests.length)     renderChart('chart-cc', ccTests);

// Timestamp
document.getElementById('gen-time').textContent = new Date().toISOString().replace('T', ' ').slice(0, 19);
document.getElementById('run-count').textContent = runs.length;
</script>
</body>
</html>
HTML_JS

# ─── Done ─────────────────────────────────────────────────────────────
FILE_SIZE=$(wc -c < "$OUTPUT_FILE" | tr -d ' ')
echo ""
echo "[INFO] comparison dashboard generated: ${OUTPUT_FILE}"
echo "[INFO] Size: ${FILE_SIZE} bytes"
echo "[INFO] Runs compared: ${#RUN_DIRS[@]}"
echo ""
echo "Open in browser: file://${OUTPUT_FILE}"
