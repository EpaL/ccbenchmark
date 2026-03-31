# ccbenchmark

Cross-platform bash benchmark for measuring the latency of native operations underlying Claude Code's tool calls — shell spawn, file I/O, git commands, grep/find, and API round-trips.

## What it measures

The benchmark creates a realistic test git repo (30+ files, multiple commits, uncommitted changes) and times these operations against it:

| Test | Operation |
|---|---|
| `shell_cmd_init` | Spawn bash, run `echo` |
| `shell_open` | Read a source file (`cat`) |
| `shell_spawn` | Read a large file through bash |
| `stdout_capture` | `git status --short` |
| `shell_exec_init` | Python interpreter startup |
| `file_edit` | `sed` in-place edit |
| `git_log_init` | `git log --oneline` |
| `git_diff` | `git diff HEAD` |
| `lookup_capture` | `grep -rn` across repo |
| `tool_lookup` | `find` by file pattern |
| `network_rtt` | `curl` round-trip to Anthropic API |

Each test runs in **cold** (single-shot) and **warm** (repeated) modes, reporting min/mean/max/stddev in milliseconds.

## Usage

```bash
chmod +x cc_latency_bench.sh
./cc_latency_bench.sh              # 3 warm iterations (default)
./cc_latency_bench.sh 10           # 10 warm iterations
./cc_latency_bench.sh 5 "baseline" # 5 iterations with a label
```

Set `ANTHROPIC_API_KEY` in your environment to enable the `network_rtt` test.

## Output

Results are saved to `results/<hostname>_<timestamp>/` containing:

- `results.csv` — raw timing data per test/iteration/mode
- `bench.log` — full run log with system info
- `system_info.json` — machine specs, versions, timer source
- `report.html` — self-contained HTML report with results table

A summary table is also printed to the terminal:

```
════════════════════════════════════════════════════════════════════════
                           BENCHMARK SUMMARY
════════════════════════════════════════════════════════════════════════
                 │         Cold (ms)         │         Warm (ms)
Test             │   Min   Mean    Max StdDev│   Min   Mean    Max StdDev
─────────────────┼───────────────────────────┼───────────────────────────
shell_cmd_init   │   4.3    4.3    4.3   0.0 │   3.8    3.9    4.1   0.2
shell_open       │   3.6    3.6    3.6   0.0 │   3.7    3.8    3.9   0.1
...
```

## High-resolution timers

The script auto-selects the best available timer to minimize measurement overhead:

| Priority | Source | Overhead | Available on |
|---|---|---|---|
| 1 | `$EPOCHREALTIME` | ~0 (bash builtin) | Bash 5.0+ |
| 2 | `date +%s%N` | ~3ms | Linux, Git Bash/Windows |
| 3 | `gdate +%s%N` | ~3ms | macOS (`brew install coreutils`) |
| 4 | `perl Time::HiRes` | ~5ms | macOS, most Linux |
| 5 | `python3 time` | ~30ms | Everywhere (last resort) |

The selected timer is logged at the start of each run.

## Platform support

| Platform | Shell | Status |
|---|---|---|
| macOS | zsh / bash | Supported |
| Linux | bash | Supported |
| Windows | Git Bash / MSYS2 | Supported |

## Requirements

- `bash` (runs as bash regardless of user's default shell)
- `git`
- `bc`
- `python3` (only for one test + timer fallback)
- `curl` (only for `network_rtt` test)
