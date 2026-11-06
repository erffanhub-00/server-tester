# Changelog

## [2.2.0] - 2026-11-06

### Changed
- Split the single 1705-line `ServerTester.ps1` into a module layout: a thin entry script plus `src/` modules (`State`, `UI`, `Config`, `Scoring`, `Worker`, `Output`, `Menu`). The entry script dot-sources the modules, so behavior is unchanged.
- Timeouts, worker count and HTTP options are now CLI parameters instead of edit-the-code constants: `-MaxWorkers`, `-PingTimeoutMs`, `-TcpTimeoutMs`, `-AppTimeoutMs`, `-HttpMethod`, `-HttpVersion`.
- Scoring fallbacks are now named constants (`$script:SCORE_NO_DATA`, `$script:SCORE_PROTO_ONLY_*` in `src/Scoring.ps1`) instead of unexplained `9999` literals. Scores are unchanged: a Down server still scores 11149.

### Added
- Duplicate servers in a category are now tested once; duplicates are listed and skipped with a warning (`Get-UniqueServers`).
- Pester tests grew from 30 to 43: dedup, score fallbacks, formatting helpers, status colors, and CLI parameter defaults (including a regression test for the `-Packets` bug below).
- README rewritten: full CLI reference, project structure, scoring fallbacks, development notes.

### Fixed
- `-Packets` was silently ignored in `-NoMenu` mode (always ran 20 packets). Root cause: `$script:PACKETS` and the `-Packets` parameter are the same variable — PowerShell names are case-insensitive — and the state initializer reset it to 20 on load. The menu state variable is now `$script:MenuPackets`.
- `Show-ServerDetail` had three unused parameters (`HttpPorts`, `HttpsPorts`, `StratumPorts`); removed.
- A failing output-directory creation now warns instead of failing silently.
- Tests fixed for Pester 6: helper functions moved into `BeforeAll` (top-level helpers are not visible to `It` blocks under Pester 6).

## [2.1.0] - 2026-11-06

- TLS certificate validation is now on by default (`-ValidateTls`, use `-ValidateTls:$false` to skip); `TlsValid` and the HTTP status code are now reported in CSV and JSON.
- An HTTP status only counts as OK for 200-399; 404/500 no longer count as OK.
- Best protocol is now the protocol of the fastest working port instead of a fixed Stratum > HTTPS > HTTP priority.
- Protocol time is now the application-layer time for HTTP, HTTPS and Stratum, so the best-port comparison is fair.
- Invalid protocol ports in a category now fail validation instead of being silently dropped.
- `-NoMenu` requires `-CategoryName` (and vice versa); `-Packets` is validated to 1-500; CLI mode no longer waits for Enter.
- Server names are validated; output filenames are sanitized.
- `categories.json`: removed the wrong ViaBTC server and port 25, removed 443 from Stratum ports, clarified the DNS category.
- Added Pester tests and CI (PSScriptAnalyzer + tests on Windows and Linux).
