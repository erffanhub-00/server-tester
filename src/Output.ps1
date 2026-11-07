# ========================================================
# Server Tester - Output
# ========================================================
# Ranking display, CSV/JSON export, server detail.
# Part of ServerTester.ps1. Dot-sourced by the entry script;
# do not run directly.

# ========================================================
# RANKING + EXPORT (SIMPLIFIED)
# ========================================================
function Show-Ranking {
    param([array]$Results, [string]$CategoryKey)

    Write-Host ""
    Write-BorderTop -Title "FINAL RANKING  -  $CategoryKey" -Color $script:Theme.Primary
    Write-Host ""

    if (-not $Results -or $Results.Count -eq 0) {
        Write-Host "  No results." -ForegroundColor $script:Theme.Warning
        return
    }

    $scored = $Results |
        Select-Object *, @{n='Score'; e={ Get-Score $_ }} |
        Sort-Object Score


    $hdr = "{0,-4}{1,-22}{2,-12}{3,8}{4,10}{5,10}{6,10}  {7,-16}{8,8}" -f `
        "#","SERVER","STATUS","LOSS","AVG","P95","JITTER","BEST","SCORE"
    Write-Host "  " -NoNewline
    Write-Host $hdr -ForegroundColor $script:Theme.Muted
    Write-BorderThin

    $rank = 1
    foreach ($r in $scored) {
        $rankColor   = Get-RankColor $rank
        $lossColor   = Get-LossColor $r.Loss
        $status      = Get-Status $r
        $statusColor = Get-StatusColor $status

        $avgStr = if ($null -eq $r.Avg)    { "N/A" } else { "{0:F1}ms" -f $r.Avg }
        $p95Str = if ($null -eq $r.P95)    { "N/A" } else { "{0:F1}ms" -f $r.P95 }
        $jitStr = if ($null -eq $r.Jitter) { "N/A" } else { "{0:F1}ms" -f $r.Jitter }

        $best = Get-BestProtocol $r
        $bestDisplay = if ($best) { "$best`:$($r.BestPort)" } else { "-" }
        if ($bestDisplay.Length -gt 15) { $bestDisplay = $bestDisplay.Substring(0,15) }

        $avgColor = "White"
        if ($null -ne $r.Avg) { $avgColor = Get-LatencyColor ([double]$r.Avg) }

        Write-Host "  " -NoNewline
        Write-Host (Get-RankIcon $rank) -ForegroundColor $rankColor -NoNewline
        Write-Host ("{0,-22}" -f $r.Host) -NoNewline
        Write-Host ("{0,-12}" -f $status) -ForegroundColor $statusColor -NoNewline
        Write-Host ("{0,7:F1}%" -f $r.Loss) -ForegroundColor $lossColor -NoNewline
        Write-Host ("{0,10}" -f $avgStr) -ForegroundColor $avgColor -NoNewline
        Write-Host ("{0,10}" -f $p95Str) -ForegroundColor $script:Theme.Warning -NoNewline
        Write-Host ("{0,10}" -f $jitStr) -ForegroundColor $script:Theme.Secondary -NoNewline
        Write-Host "  " -NoNewline
        Write-Host ("{0,-16}" -f $bestDisplay) -ForegroundColor $script:Theme.Accent -NoNewline
        Write-Host ("{0,8:F1}" -f $r.Score) -ForegroundColor $script:Theme.Highlight

        $rank++
    }

    Write-Host ""
    Write-BorderTop -Color $script:Theme.Primary

    $top = $scored | Select-Object -First 1
    Write-Host ""
    Write-Host "  " -NoNewline
    Write-Host "* TOP RANKED " -ForegroundColor $script:Theme.Success -NoNewline
    Write-Host "  " -NoNewline
    Write-Host $top.Host -ForegroundColor $script:Theme.Primary -NoNewline
    Write-Host "   " -NoNewline
    Write-Host "(best port: " -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host "$($top.BestPort)" -ForegroundColor $script:Theme.Warning -NoNewline
    Write-Host ")" -ForegroundColor $script:Theme.Muted
    Write-Host ""

    # ---------- Export ----------
    $ts       = Get-Date -Format 'yyyyMMdd_HHmmss'
    $safeKey  = $CategoryKey -replace '[^a-zA-Z0-9_-]', '_'
    $csvName  = "server_tester_${safeKey}_${ts}.csv"
    $csv      = Join-Path $script:OutputPath $csvName
    $jsonName = "server_tester_${safeKey}_${ts}.json"
    $json     = Join-Path $script:OutputPath $jsonName

    # CSV export
    try {
        $rankIdx = 1
        $csvData = foreach ($s in $scored) {
            $bestEntry = Get-BestPortEntry $s
            [PSCustomObject]@{
                "Rank"           = $rankIdx
                "Server"         = $s.Host
                "IP"             = $s.IP
                "Category"       = $s.Category
                "Status"         = Get-Status $s
                "Packet Loss %"  = $s.Loss
                "Avg Latency"    = $s.Avg
                "P95 Latency"    = $s.P95
                "Jitter"         = $s.Jitter
                "Best Port"      = $s.BestPort
                "Best Protocol"  = Get-BestProtocol $s
                "TLS Valid"      = $bestEntry.TlsValid
                "HTTP Status"    = $bestEntry.Status
                "Score"          = $s.Score
            }
            $rankIdx++
        }
        $csvData | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
        Write-Host "  " -NoNewline
        Write-Host "[CSV]  " -ForegroundColor $script:Theme.Success -NoNewline
        Write-Host $csv -ForegroundColor $script:Theme.Muted
    } catch {
        Write-Host "  [ERR] CSV: $($_.Exception.Message)" -ForegroundColor $script:Theme.Danger
    }

    # JSON export
    try {
        $jsonData = @()
        $rankIdx = 1
        foreach ($s in $scored) {
            # ports as real arrays
            $tcpArr = @()
            if ($s.TcpOpenPorts -and $s.TcpOpenPorts -ne "") {
                $tcpArr = @($s.TcpOpenPorts -split "," | ForEach-Object { [int]$_ })
            }
            $stratArr = @()
            if ($s.StratumPorts -and $s.StratumPorts -ne "") {
                $stratArr = @($s.StratumPorts -split "," | ForEach-Object { [int]$_ })
            }
            $httpsArr = @()
            if ($s.HttpsPorts -and $s.HttpsPorts -ne "") {
                $httpsArr = @($s.HttpsPorts -split "," | ForEach-Object { [int]$_ })
            }
            $httpArr = @()
            if ($s.HttpPorts -and $s.HttpPorts -ne "") {
                $httpArr = @($s.HttpPorts -split "," | ForEach-Object { [int]$_ })
            }

            # best latency from PortResults
            $bestEntry = Get-BestPortEntry $s
            $bestLatency = $null
            if ($bestEntry -and $null -ne $bestEntry.ProtocolTime) {
                $bestLatency = [double]$bestEntry.ProtocolTime
            }

            $jsonData += [ordered]@{
                rank     = $rankIdx
                server   = $s.Host
                ip       = $s.IP
                category = $s.Category
                status   = Get-Status $s

                latency = [ordered]@{
                    avg_ms    = $s.Avg
                    min_ms    = $s.Min
                    max_ms    = $s.Max
                    p95_ms    = $s.P95
                    jitter_ms = $s.Jitter
                }

                packets = [ordered]@{
                    sent     = $s.Success + $s.Failed
                    received = $s.Success
                    lost     = $s.Failed
                    loss_pct = $s.Loss
                }

                ports = [ordered]@{
                    tcp_open      = $tcpArr
                    stratum_ok    = $stratArr
                    https_ok      = $httpsArr
                    http_ok       = $httpArr
                    best          = if ($s.BestPort) { [int]$s.BestPort } else { $null }
                    best_protocol = Get-BestProtocol $s
                    best_latency_ms = $bestLatency
                    tls_valid     = $bestEntry.TlsValid
                    http_status   = $bestEntry.Status
                }

                score = $s.Score
            }
            $rankIdx++
        }

        $jsonData | ConvertTo-Json -Depth 5 | Set-Content -Path $json -Encoding UTF8
        Write-Host "  " -NoNewline
        Write-Host "[JSON] " -ForegroundColor $script:Theme.Success -NoNewline
        Write-Host $json -ForegroundColor $script:Theme.Muted
    } catch {
        Write-Host "  [ERR] JSON: $($_.Exception.Message)" -ForegroundColor $script:Theme.Danger
    }

    Write-Host ""
}

# ========================================================
# SERVER DETAIL
# ========================================================
function Show-ServerDetail {
    param($r, [int[]]$Ports)

    $status = Get-Status $r
    $statusColor = Get-StatusColor $status

    Write-Host ""
    Write-BorderThin
    Write-Host "  " -NoNewline
    Write-Host "HOST  " -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host $r.Host -ForegroundColor $script:Theme.Primary -NoNewline
    Write-Host "   " -NoNewline
    Write-Host "[$status]" -ForegroundColor $statusColor
    Write-BorderThin

    Write-Host "  " -NoNewline
    Write-Host "IP          " -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host ("{0,-24}" -f $r.IP) -ForegroundColor $script:Theme.Highlight -NoNewline
    Write-Host "Category    " -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host $r.Category

    Write-Host "  " -NoNewline
    Write-Host "Packets     " -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host ("{0,-24}" -f "$($r.Success) / $($r.Success + $r.Failed) received") -ForegroundColor $script:Theme.Success -NoNewline
    Write-Host "Loss        " -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host (Format-Pct $r.Loss) -ForegroundColor (Get-LossColor $r.Loss)

    Write-Host ""
    Write-Host "  " -NoNewline
    Write-Host "ICMP LATENCY" -ForegroundColor $script:Theme.Muted
    Write-BorderThin

    $metrics = @(
        @{ Label = "Min";     Value = $r.Min; Color = $script:Theme.Success }
        @{ Label = "P50";     Value = $r.P50; Color = $script:Theme.Primary }
        @{ Label = "Average"; Value = $r.Avg; Color = $script:Theme.Primary }
        @{ Label = "P95";     Value = $r.P95; Color = $script:Theme.Warning }
        @{ Label = "P99";     Value = $r.P99; Color = $script:Theme.Warning }
        @{ Label = "Max";     Value = $r.Max; Color = $script:Theme.Danger  }
    )

    foreach ($m in $metrics) {
        $val = if ($null -eq $m.Value) { "N/A" } else { Format-Ms $m.Value }
        Write-Host "  " -NoNewline
        Write-Host ("{0,-10}" -f $m.Label) -ForegroundColor $script:Theme.Muted -NoNewline
        Write-Host ("{0,-14}" -f $val) -ForegroundColor $m.Color -NoNewline

        if ($null -ne $m.Value -and $null -ne $r.Max -and [double]$r.Max -gt 0) {
            $ratio = [double]$m.Value / [double]$r.Max
            $barLen = 30
            $filled = [Math]::Min($barLen, [Math]::Max(0, [int]([Math]::Round($ratio * $barLen))))
            $empty  = $barLen - $filled
            Write-Host "  " -NoNewline
            Write-Host ("#" * $filled) -ForegroundColor $m.Color -NoNewline
            Write-Host ("." * $empty) -ForegroundColor $script:Theme.Muted
        } else {
            Write-Host ""
        }
    }

    Write-Host ""
    Write-Host "  " -NoNewline
    Write-Host "PORT SCAN" -ForegroundColor $script:Theme.Muted
    Write-BorderThin

    $detailsMap = @{}
    if ($r.PortResults) {
        foreach ($e in $r.PortResults) {
            $detailsMap["$($e.Port)"] = @{
                protocol = $e.Protocol
                tcp      = if ($null -eq $e.TcpTime) { "-" } else { "{0:F1}" -f $e.TcpTime }
                app      = if ($null -eq $e.ProtocolTime) { "-" } else { "{0:F1}" -f $e.ProtocolTime }
                state    = if ($e.ProtocolOk) { "OK" } else { "FAIL" }
                status   = $e.Status
                tlsValid = $e.TlsValid
            }
        }
    }


    foreach ($p in $Ports) {
        $pStr = "$p"
        Write-Host "  " -NoNewline

        if ($detailsMap.ContainsKey($pStr)) {
            $d = $detailsMap[$pStr]
            $protoTag = switch ($d.protocol) {
                "stratum" { "Stratum" }
                "http"    { "HTTP"    }
                "https"   { "HTTPS"   }
                default   { "TCP"     }
            }

            if ($d.tcp -ne "-") {
                $stateColor = if ($d.state -like "OK*") { $script:Theme.Success } else { $script:Theme.Warning }

                $tcpPart = if ($d.tcp -ne "-") { "tcp {0,7} ms" -f $d.tcp } else { "tcp     -    " }
                $appPart = if ($d.app -ne "-") { "  app {0,7} ms" -f $d.app } else { "           " }

                Write-Host ("  {0,-6}" -f $p) -ForegroundColor $script:Theme.Highlight -NoNewline
                Write-Host " OPEN  " -ForegroundColor $script:Theme.Success -NoNewline
                Write-Host $tcpPart -ForegroundColor $script:Theme.Muted -NoNewline
                Write-Host $appPart -ForegroundColor $script:Theme.Muted -NoNewline
                $stateText = $d.state
                if ($null -ne $d.status) { $stateText += " [HTTP $($d.status)]" }
                if ($d.tlsValid -eq $false) { $stateText += " [TLS invalid]" }
                Write-Host "  $protoTag " -ForegroundColor $script:Theme.Primary -NoNewline
                Write-Host $stateText -ForegroundColor $stateColor
            }
        } else {
            Write-Host ("  {0,-6}" -f $p) -ForegroundColor $script:Theme.Highlight -NoNewline
            Write-Host " CLOSED" -ForegroundColor $script:Theme.Danger
        }
    }
    Write-BorderThin
}
