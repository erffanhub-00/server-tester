# 🚀 Server Tester - POWER EDITION

<p align="center">
  <img src="https://img.shields.io/badge/PowerShell-5.1%2B-blue?style=for-the-badge&logo=powershell">
  <img src="https://img.shields.io/badge/Platform-Windows%20%7C%20Linux%20%7C%20macOS-informational?style=for-the-badge">
  <img src="https://img.shields.io/badge/Version-v2.1.0-success?style=for-the-badge">
  <img src="https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge">
</p>

**Multi-protocol network tester for mining pools, CDNs, DNS and more.**

Server Tester is a PowerShell CLI tool for testing network latency, packet loss, jitter, TCP connectivity, and application-level protocols across multiple servers simultaneously. It uses an independent layered measurement model for **ICMP, TCP, and application-level testing**.

---

## ✨ Features

* 🌐 **Layered network testing**
  * ICMP latency
  * TCP connection time
  * Application protocol handshake

* ⚡ **Parallel testing** with PowerShell runspaces

* 🔌 **ICMP, TCP, HTTP, HTTPS and Stratum V1**

* 📊 **Full statistics** — Min / Avg / P50 / P95 / P99 / Max

* 📈 **Jitter, standard deviation and packet loss**

* 🎯 **User-friendly Status** — `OK` / `Reachable` / `Degraded` / `Down`

* 🧩 **JSON-based configuration** with strict validation

* 📁 **Clean output** — Simplified CSV + Structured JSON

* ⏱️ **Hard test deadline** with forced worker stop

* 🖥️ **Interactive menu + CLI mode**

* 🌍 **Windows / Linux / macOS**

* 📦 **No external dependencies**

---

## 🏗️ Architecture

The main idea is to measure each network layer independently:

```text
Server
  │
  ├── Layer 1 → ICMP
  │              Network latency
  │
  ├── Layer 2 → TCP
  │              Connection time
  │
  └── Layer 3 → Application
                 HTTP / HTTPS / Stratum
```

For example:

```text
ICMP  → 20 ms
TCP   → 35 ms
HTTPS → 80 ms
```

Each value is measured independently and is not derived from another layer.

---

## 📁 Project Structure

```text
server-tester/
├── ServerTester.ps1
├── categories.json
├── LICENSE
├── .gitignore
├── .gitattributes
├── run.bat
├── run.sh
└── output/
    └── .gitkeep
```

---

## 📥 Installation

No installation required.

```bash
git clone https://github.com/erffanhub-00/server-tester.git
cd server-tester
```

### Windows

```cmd
run.bat
```

Or:

```powershell
powershell -ExecutionPolicy Bypass -File ServerTester.ps1
```

### Linux / macOS

```bash
chmod +x run.sh
./run.sh
```

Or:

```bash
pwsh -File ServerTester.ps1
```

---

## ⚡ Quick Start

### Interactive

```powershell
pwsh -File ServerTester.ps1
```

### CLI

```powershell
pwsh -File ServerTester.ps1 `
    -CategoryName mining_viabtc `
    -Packets 50 `
    -NoMenu
```

### Custom configuration

```powershell
pwsh -File ServerTester.ps1 `
    -ConfigFile my-categories.json `
    -CategoryName custom `
    -Packets 25 `
    -NoMenu
```

---

## 📋 CLI Reference

| Parameter       | Default           | Description                     |
| --------------- | ----------------- | ------------------------------- |
| `-CategoryName` | —                 | Category from `categories.json` |
| `-Packets`      | `20`              | Number of ICMP tests per server |
| `-ConfigFile`   | `categories.json` | Configuration file              |
| `-OutputDir`    | `output`          | Report directory                |
| `-NoMenu`       | Off               | Skip interactive menu           |

Packet range:

```text
1 - 500
```

---

## ⚙️ Configuration

Categories are defined in `categories.json`.

```json
{
  "mining_viabtc": {
    "name": "ViaBTC Mining Pools",
    "description": "ViaBTC Stratum mining endpoints",
    "servers": [
      "btc.viabtc.io",
      "btc.viabtc.cc"
    ],
    "ports": [3333, 443, 80],
    "stratum_ports": [3333],
    "http_ports": [80],
    "https_ports": [443]
  }
}
```

### Configuration rules

* Ports must be between `1-65535`
* Protocol ports must exist in `ports`
* A port can belong to only one application protocol
* Ports without a protocol are tested with TCP only

---

## 📊 Statistics

The tool reports:

| Metric  | Description                         |
| ------- | ----------------------------------- |
| Loss    | Packet loss percentage              |
| Min     | Minimum latency                     |
| Avg     | Average latency                     |
| P50     | Median latency                      |
| P95     | 95th percentile                     |
| P99     | 99th percentile                     |
| Max     | Maximum latency                     |
| Jitter  | Mean consecutive latency difference |
| Std Dev | Latency variation                   |

---

## 🎯 Server Status Classification

Each server gets a clear status so you can understand results at a glance:

| Status | Meaning |
|--------|---------|
| ✅ **OK** | No packet loss + at least one working application protocol |
| 🔵 **Reachable** | No packet loss, but no working application protocol |
| ⚠️ **Degraded** | Some packet loss (between 0% and 100%) |
| ❌ **Down** | 100% packet loss |

---

## 📤 Output

Results are automatically exported as **CSV** and **JSON** — both user-friendly.

### CSV — Simplified, 12 columns

```csv
"Rank","Server","IP","Category","Status","Packet Loss %","Avg Latency","P95 Latency","Jitter","Best Port","Best Protocol","Score"
"1","1.1.1.1","1.1.1.1","dns","OK","0","148.3","165","12.89","443","HTTPS","101.02"
"2","9.9.9.9","9.9.9.9","dns","Reachable","0","147.75","165","9.95","","","259.86"
"5","208.67.222.222","208.67.222.222","dns","Down","100",,,,"","","11149"
```

**Perfect for Excel, Google Sheets, or any spreadsheet tool.**

### JSON — Structured for automation

```json
[
  {
    "rank": 1,
    "server": "1.1.1.1",
    "ip": "1.1.1.1",
    "category": "dns",
    "status": "OK",
    "latency": {
      "avg_ms": 148.3,
      "min_ms": 126,
      "max_ms": 173,
      "p95_ms": 165,
      "jitter_ms": 12.89
    },
    "packets": {
      "sent": 20,
      "received": 20,
      "lost": 0,
      "loss_pct": 0
    },
    "ports": {
      "tcp_open": [53, 443],
      "stratum_ok": [],
      "https_ok": [443],
      "http_ok": [],
      "best": 443,
      "best_protocol": "HTTPS",
      "best_latency_ms": 643.8
    },
    "score": 101.02
  }
]
```

**Perfect for dashboards, automation, and analysis tools.**

### File naming

```text
output/
├── server_tester_<category>_<timestamp>.csv
└── server_tester_<category>_<timestamp>.json
```

Example:

```text
[CSV]  output/server_tester_dns_20260920_012030.csv
[JSON] output/server_tester_dns_20260920_012030.json
```

---

## 🧮 Scoring

The project includes a **project-specific heuristic score**.

```text
score =
(loss × 10)
+ (avg × 0.5)
+ (jitter × 0.3)
+ (p95 × 0.2)
+ protocol_bonus
```

Protocol bonuses:

```text
Stratum working       -30
HTTPS working         -10
HTTP working            0
No protocol working  +150
```

> The score is not an industry standard or universal network-quality metric.

---

## 🗂️ Included Categories

The project includes predefined categories for:

* ⛏️ ViaBTC Mining Pools
* ⛏️ Major Mining Pools
* 🌐 CDN Endpoints
* 🧭 Public DNS Resolvers
* ☁️ Cloud Providers
* 💱 Crypto Exchanges
* 🧪 Custom Test Set

---

## 📸 Demo

> Screenshots and demo GIF will be added here.

```text
docs/
├── screenshots/
│   ├── menu.png
│   ├── results.png
│   └── ranking.png
└── demo.gif
```

### Sample Output

```text
======================================================================================================================
                                                    SERVER TESTER
                                               POWER EDITION  -  v2.1.0
======================================================================================================================

  RESULTS  Public DNS Resolvers
======================================================================================================================

----------------------------------------------------------------------------------------------------------------------
  HOST  1.1.1.1   [OK]
----------------------------------------------------------------------------------------------------------------------
  IP          1.1.1.1                 Category    dns
  Packets     20 / 20 received        Loss        0.0%

  ICMP LATENCY
----------------------------------------------------------------------------------------------------------------------
  Min       126.0 ms        ######################........
  P50       149.0 ms        ##########################....
  Average   148.3 ms        ##########################....
  P95       165.0 ms        #############################.
  P99       173.0 ms        ##############################
  Max       173.0 ms        ##############################

  PORT SCAN
----------------------------------------------------------------------------------------------------------------------
    53     OPEN  tcp   152.8 ms             TCP FAIL
    443    OPEN  tcp   143.9 ms  app   643.8 ms  HTTPS OK [HTTP 301]
----------------------------------------------------------------------------------------------------------------------

==============================================  FINAL RANKING  -  dns  ===============================================

  #   SERVER                STATUS          LOSS       AVG       P95    JITTER  BEST               SCORE
----------------------------------------------------------------------------------------------------------------------
   1 1.1.1.1               OK              0.0%   148.3ms   165.0ms    12.9ms  HTTPS:443          101.0
   2 9.9.9.9               Reachable       0.0%   147.8ms   165.0ms    10.0ms  -                  259.9
   3 8.8.4.4               Reachable       0.0%   148.8ms   165.0ms    12.0ms  -                  261.0
   4 8.8.8.8               Degraded        5.0%   150.8ms   173.0ms    17.4ms  -                  315.3
   5 208.67.222.222        Down          100.0%       N/A       N/A       N/A  -                11149.0

======================================================================================================================

  * TOP RANKED   1.1.1.1   (best port: 443)
```

---

## ⚠️ Known Limitations

* ICMP may be blocked by firewalls or ISPs.
* TCP/application tests may still work when ICMP fails.
* TLS certificate validation is disabled by default.
* Stratum V1 is supported; Stratum V2 is not.
* P95/P99 are less meaningful with very small packet counts.
* Network results can vary depending on routing, congestion, ISP, and server load.

---

## 💻 Requirements

* PowerShell 5.1+ on Windows
* PowerShell 7+ on Linux/macOS
* Network access to target servers
* No external dependencies

---

## 🤝 Contributing

Contributions are welcome.

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test them
5. Open a Pull Request

Bug reports and feature requests are also welcome.

---

## 📜 License

MIT License — see [`LICENSE`](LICENSE).

---

## ⚠️ Disclaimer

Use this tool only for servers and infrastructure you own or have permission to test.

Do not use it to attack, overload, or scan unauthorized infrastructure. Respect rate limits, terms of service, and applicable laws.

---

## 👤 Author

### Erffan

Computer Engineering Student focused on **AI, Tools & 3D Printing**.

[![Telegram](https://img.shields.io/badge/Telegram-erffan__hub-blue?style=for-the-badge\&logo=telegram)](https://t.me/erffan_hub)
[![Twitter](https://img.shields.io/badge/Twitter-@Erffanhub__00-000000?style=for-the-badge\&logo=x\&logoColor=white)](https://x.com/Erffanhub_00)
[![Gist](https://img.shields.io/badge/Gist-Profile-000000?style=for-the-badge\&logo=github)](https://gist.github.com/erffanhub-00)
[![GitHub](https://img.shields.io/badge/GitHub-Profile-000000?style=for-the-badge\&logo=github)](https://github.com/erffanhub-00)

---

## 🔗 Repository

https://github.com/erffanhub-00/server-tester

⭐ **Star the repository if you find it useful.**
