# Server Tester — POWER EDITION

Multi-protocol network tester for mining pools, CDNs, DNS and more.

[![CI](https://github.com/erffanhub-00/server-tester/actions/workflows/ci.yml/badge.svg)](https://github.com/erffanhub-00/server-tester/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE) [![Version](https://img.shields.io/badge/Version-v2.2.0-success?style=for-the-badge)](CHANGELOG.md)

Server Tester is a PowerShell CLI tool that tests network latency, packet loss, jitter, TCP connectivity and application-level protocols across multiple servers at the same time. Each layer is measured independently — ICMP, TCP, then the application protocol (HTTP / HTTPS / Stratum) — so a slow HTTPS result does not hide a fast network underneath.

## Features

- Layered testing: ICMP latency, TCP connection time, application protocol handshake
- Parallel testing with PowerShell runspaces (tunable with `-MaxWorkers`)
- Protocols: ICMP, TCP, HTTP, HTTPS, Stratum V1
- TLS certificate validation, on by default (`-ValidateTls`)
- Full statistics: Min / Avg / P50 / P95 / P99 / Max, jitter, standard deviation, packet loss
- Status per server: `OK` / `Reachable` / `Degraded` / `Down`
- JSON-based configuration with strict validation (bad ports, bad host names and duplicate servers are caught before testing)
- Clean output: simplified CSV + structured JSON
- Hard test deadline with forced worker stop
- Interactive menu + CLI mode
- Windows / Linux / macOS, no external dependencies

## Quickstart

No installation required. PowerShell 7+ is recommended on all platforms; Windows PowerShell 5.1 also runs the tool via `run.bat`, but it is not covered by CI. On Linux, ICMP ping may need elevated privileges (CAP_NET_RAW) or root.

```bash
git clone https://github.com/erffanhub-00/server-tester.git
cd server-tester
```

Windows:

```cmd
run.bat
```

Linux / macOS:

```bash
./run.sh
```

Or on any platform:

```powershell
pwsh -File ServerTester.ps1
```

`run.bat` prefers `pwsh` (PowerShell 7) and falls back to Windows PowerShell 5.1. `run.sh` checks that `pwsh` exists and is version 7 or later.

## Usage

Interactive menu:

```powershell
pwsh -File ServerTester.ps1
```

Test one category from the command line:

```powershell
pwsh -File ServerTester.ps1 -CategoryName mining_viabtc -Packets 50 -NoMenu
```

Custom configuration file:

```powershell
pwsh -File ServerTester.ps1 -ConfigFile my-categories.json -CategoryName custom -Packets 25 -NoMenu
```

Fewer workers, longer timeouts:

```powershell
pwsh -File ServerTester.ps1 -CategoryName cdn -Packets 10 -MaxWorkers 5 -AppTimeoutMs 10000 -NoMenu
```

### CLI reference

| Parameter | Default | Description |
| --------- | ------- | ----------- |
| `-CategoryName` | — | Category from `categories.json` |
| `-Packets` | `20` | Number of ICMP tests per server (1-500, enforced) |
| `-ConfigFile` | `categories.json` | Configuration file |
| `-OutputDir` | `output` | Report directory |
| `-NoMenu` | Off | Skip interactive menu (requires `-CategoryName`) |
| `-ValidateTls` | `true` | Validate TLS certificates (use `-ValidateTls:$false` to skip) |
| `-MaxWorkers` | `20` | Max parallel workers (1-50) |
| `-PingTimeoutMs` | `2000` | ICMP timeout per packet in ms (100-60000) |
| `-TcpTimeoutMs` | `3000` | TCP connect timeout in ms (100-60000) |
| `-AppTimeoutMs` | `5000` | Application test timeout in ms (100-60000) |
| `-HttpMethod` | `HEAD` | HTTP method: `HEAD` or `GET` |
| `-HttpVersion` | `1.1` | HTTP version: `1.0` or `1.1` |

`-NoMenu` without `-CategoryName` (or vice versa) is an error and exits with code 1.

### Configuration

Categories are defined in `categories.json`:

```json
{
  "mining_viabtc": {
    "name": "ViaBTC Mining Pools",
    "description": "ViaBTC Stratum mining endpoints",
    "servers": ["btc.viabtc.io", "btc.viabtc.cc"],
    "ports": [3333, 443, 80],
    "stratum_ports": [3333],
    "http_ports": [80],
    "https_ports": [443]
  }
}
```

Validation rules:

- Ports must be between 1-65535
- Protocol ports must exist in `ports`
- A port can belong to only one application protocol; ports without a protocol are tested with TCP only
- Server names must be valid host names or IPs (letters, digits, `. - : [ ]` only — no spaces or line breaks, so no header injection is possible)
- Duplicate servers in a category are tested once; the duplicates are listed and skipped with a warning

A category that fails validation is skipped with a clear error message instead of crashing the run.

Included categories: ViaBTC Mining Pools, Major Mining Pools, CDN Endpoints, Public DNS Resolvers, Cloud Providers, Crypto Exchanges, Custom Test Set. The `dns` category only checks TCP/HTTPS reachability of public DNS servers — it does not send a real DNS query.

### Statistics

| Metric | Description |
| ------ | ----------- |
| Loss | Packet loss percentage |
| Min / Avg / P50 / P95 / P99 / Max | Latency percentiles |
| Jitter | Mean consecutive latency difference |
| Std Dev | Latency variation |

### Server status

| Status | Meaning |
| ------ | ------- |
| OK | No packet loss + at least one working application protocol |
| Reachable | No packet loss, but no working application protocol |
| Degraded | Some packet loss (between 0% and 100%) |
| Down | 100% packet loss |

### Output

Results are exported automatically as CSV and JSON to `output/server_tester_<category>_<timestamp>.csv` / `.json`.

CSV — simplified, 14 columns:

```csv
"Rank","Server","IP","Category","Status","Packet Loss %","Avg Latency","P95 Latency","Jitter","Best Port","Best Protocol","TLS Valid","HTTP Status","Score"
"1","1.1.1.1","1.1.1.1","dns","OK","0","148.3","165","12.89","443","HTTPS","True","301","101.02"
"5","208.67.222.222","208.67.222.222","dns","Down","100",,,,"","","","","11149"
```

An HTTP status only counts as OK for 200-399; a 404 or 500 is not OK. `TLS Valid` is `True` only when TLS validation actually ran and passed, `False` when the certificate failed validation, and empty when validation was skipped or not applicable.

JSON — structured, one object per server:

```json
[
  {
    "rank": 1,
    "server": "1.1.1.1",
    "ip": "1.1.1.1",
    "category": "dns",
    "status": "OK",
    "latency": { "avg_ms": 148.3, "min_ms": 126, "max_ms": 173, "p95_ms": 165, "jitter_ms": 12.89 },
    "packets": { "sent": 20, "received": 20, "lost": 0, "loss_pct": 0 },
    "ports": { "tcp_open": [53, 443], "https_ok": [443], "best": 443, "best_protocol": "HTTPS", "tls_valid": true, "http_status": 301 },
    "score": 101.02
  }
]
```

### Scoring

A project-specific heuristic score. Lower is better.

```text
score = (loss x 10) + (avg x 0.5) + (jitter x 0.3) + (p95 x 0.2) + protocol_bonus
```

Protocol bonuses: Stratum working -30, HTTPS working -10, HTTP working 0, no protocol working +150. The score is not an industry standard or universal network-quality metric.

When a server returns no ICMP samples at all, the score uses named fallbacks (`$script:SCORE_NO_DATA` and `$script:SCORE_PROTO_ONLY_*` in `src/Scoring.ps1`) instead of silently inventing numbers:

- No ICMP data and no working protocol: avg/jitter/p95 fall back to **9999**, so the server always sorts last. A Down server (100% loss, no protocol) therefore scores **11149** = 100x10 + 9999x0.5 + 9999x0.3 + 9999x0.2 + 150.
- No ICMP data but an application protocol still answers: the server is reachable, so pessimistic but finite fallbacks apply (avg 500, jitter 100, p95 500).

### Known limitations

- ICMP may be blocked by firewalls or ISPs; TCP/application tests may still work when ICMP fails.
- TLS validation is enabled by default; pass `-ValidateTls:$false` to skip it (not recommended).
- Stratum V1 is supported; Stratum V2 is not.
- P95/P99 are less meaningful with very small packet counts.
- Results vary with routing, congestion, ISP and server load.
- There is no built-in rate limiting beyond `-MaxWorkers` and `-Packets` — point it only at servers you own or have permission to test, and lower both values for fragile targets.

## Project structure

```text
server-tester/
├── ServerTester.ps1          # Entry script: parameters, paths, module loading
├── ServerTester.Tests.ps1    # Pester tests
├── src/
│   ├── State.ps1             # Version, constants, theme, cleanup
│   ├── UI.ps1                # Console output primitives
│   ├── Config.ps1            # categories.json loading and validation
│   ├── Scoring.ps1           # Status, scoring, best-port selection
│   ├── Worker.ps1            # Parallel measurement worker (ICMP/TCP/HTTP/HTTPS/Stratum)
│   ├── Output.ps1            # Ranking display, CSV/JSON export, server detail
│   └── Menu.ps1              # Interactive menu, category picker, test runs
├── categories.json
├── CHANGELOG.md
├── LICENSE
├── .gitignore
├── .gitattributes
├── run.bat
├── run.sh
└── output/
    └── .gitkeep
```

`ServerTester.ps1` is a thin entry point: it reads the CLI parameters, resolves the config/output paths, dot-sources the modules in `src/` (same script scope, so all `$script:` state is shared), and then runs the menu or a single category. The measurement worker (`$script:WorkerScript` in `src/Worker.ps1`) is self-contained on purpose — runspaces cannot see the main session, so every function it needs lives inside it.

## Development

Run the tests (Pester 5 or later):

```powershell
Invoke-Pester -Path ServerTester.Tests.ps1 -Output Detailed
```

Lint (PSScriptAnalyzer, errors fail CI):

```powershell
Invoke-ScriptAnalyzer -Path ServerTester.ps1 -Severity Error
Invoke-ScriptAnalyzer -Path src -Severity Error
```

Notes for contributors:

- The interactive UI intentionally uses `Write-Host` — this is a console tool, and machine-readable output is the CSV/JSON export. PSScriptAnalyzer warnings about `Write-Host` are expected.
- The empty `catch {}` blocks are all best-effort cleanup (closing sockets, disposing runspaces, clearing the console) or documented non-fatal paths (DNS failure → IP `N/A`, incomplete Stratum JSON → keep reading). A failing cleanup must not raise a second error.
- `Get-Percentile` lives inside the worker scriptblock (`src/Worker.ps1`) because runspaces cannot see the main session; the tests extract it via AST for unit testing.

Contributions are welcome: fork, create a feature branch, make your changes, run the tests, and open a pull request. Bug reports and feature requests are welcome too.

## License

MIT License — see [LICENSE](LICENSE). Use this tool only for servers and infrastructure you own or have permission to test.

Built by [Erffan](https://github.com/erffanhub-00).

---

## Me
[![Telegram](https://img.shields.io/badge/Telegram-erffan__hub-blue?style=for-the-badge&logo=telegram)](https://t.me/erffan_hub)
[![Twitter](https://img.shields.io/badge/Twitter-@Erffanhub__00-000000?style=for-the-badge&logo=x&logoColor=white)](https://x.com/Erffanhub_00)
[![Gist](https://img.shields.io/badge/Gist-Profile-000000?style=for-the-badge&logo=github)](https://gist.github.com/erffanhub-00)
[![Github](https://img.shields.io/badge/Github-Profile-000000?style=for-the-badge&logo=github)](https://github.com/erffanhub-00)
