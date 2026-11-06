# Changelog

## Unreleased

- TLS certificate validation is now on by default (`-ValidateTls`, use `-ValidateTls:$false` to skip); `TlsValid` and the HTTP status code are now reported in CSV and JSON.
- An HTTP status only counts as OK for 200-399; 404/500 no longer count as OK.
- Best protocol is now the protocol of the fastest working port instead of a fixed Stratum > HTTPS > HTTP priority.
- Protocol time is now the application-layer time for HTTP, HTTPS and Stratum, so the best-port comparison is fair.
- Invalid protocol ports in a category now fail validation instead of being silently dropped.
- `-NoMenu` requires `-CategoryName` (and vice versa); `-Packets` is validated to 1-500; CLI mode no longer waits for Enter.
- Server names are validated; output filenames are sanitized.
- `categories.json`: removed the wrong ViaBTC server and port 25, removed 443 from Stratum ports, clarified the DNS category.
- Added Pester tests and CI (PSScriptAnalyzer + tests on Windows and Linux).
