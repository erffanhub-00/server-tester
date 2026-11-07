# ========================================================
# Server Tester - Scoring
# ========================================================
# Status classification, scoring, best-port selection.
# Part of ServerTester.ps1. Dot-sourced by the entry script;
# do not run directly.

# ========================================================
# STATUS CLASSIFICATION (user-friendly)
# ========================================================
function Get-Status {
    param($Row)

    if ($Row.Loss -ge 100) { return "Down" }

    $hasApp = ($Row.StratumPorts -and $Row.StratumPorts -ne "") -or
              ($Row.HttpsPorts   -and $Row.HttpsPorts   -ne "") -or
              ($Row.HttpPorts    -and $Row.HttpPorts    -ne "")

    if ($hasApp) {
        if ($Row.Loss -gt 0) { return "Degraded" }
        return "OK"
    }

    if ($Row.Loss -gt 0) { return "Degraded" }
    return "Reachable"
}

function Get-StatusColor {
    param([string]$Status)
    switch ($Status) {
        "OK"        { return "Green" }
        "Reachable" { return "Cyan" }
        "Degraded"  { return "Yellow" }
        "Down"      { return "Red" }
        default     { return "White" }
    }
}

function Get-BestProtocol {
    param($Row)

    # Best protocol is the protocol of the chosen best port.
    if ($Row.BestProtocol) {
        switch ($Row.BestProtocol) {
            "stratum" { return "Stratum" }
            "https"   { return "HTTPS" }
            "http"    { return "HTTP" }
            default   { return "" }
        }
    }

    if ($Row.PortResults) {
        $entry = Get-BestPortEntry $Row
        if ($entry) {
            switch ($entry.Protocol) {
                "stratum" { return "Stratum" }
                "https"   { return "HTTPS" }
                "http"    { return "HTTP" }
                default   { return "" }
            }
        }
        return ""
    }

    if     ($Row.StratumPorts -and $Row.StratumPorts -ne "") { return "Stratum" }
    elseif ($Row.HttpsPorts   -and $Row.HttpsPorts   -ne "") { return "HTTPS" }
    elseif ($Row.HttpPorts    -and $Row.HttpPorts    -ne "") { return "HTTP" }
    else                                                     { return "" }
}

function Get-BestPortEntry {
    param($Row)
    if (-not $Row.PortResults -or -not $Row.BestPort) { return $null }
    return @($Row.PortResults | Where-Object { "$($_.Port)" -eq "$($Row.BestPort)" }) | Select-Object -First 1
}

# ========================================================
# SCORING
# ========================================================
# Fallback values for Get-Score when a server returns no ICMP samples.
# SCORE_NO_DATA is deliberately huge so a server with no data at all
# always sorts last: a Down server (100% loss, no protocol) scores 11149
# (100*10 + 9999*0.5 + 9999*0.3 + 9999*0.2 + 150).
$script:SCORE_NO_DATA = 9999.0
# When ICMP fails but an application protocol still answers, the server is
# reachable, so use pessimistic but finite fallbacks instead.
$script:SCORE_PROTO_ONLY_AVG    = 500.0
$script:SCORE_PROTO_ONLY_JITTER = 100.0
$script:SCORE_PROTO_ONLY_P95    = 500.0

function Get-Score {
    param($Row)

    $lossScore = [double]$Row.Loss

    $hasProto = ($Row.StratumPorts -and $Row.StratumPorts -ne "") -or
                ($Row.HttpsPorts   -and $Row.HttpsPorts   -ne "") -or
                ($Row.HttpPorts    -and $Row.HttpPorts    -ne "")

    $avgScore = if ($null -ne $Row.Avg)      { [double]$Row.Avg }
                elseif ($hasProto)           { $script:SCORE_PROTO_ONLY_AVG }
                else                         { $script:SCORE_NO_DATA }

    $jitScore = if ($null -ne $Row.Jitter)   { [double]$Row.Jitter }
                elseif ($hasProto)           { $script:SCORE_PROTO_ONLY_JITTER }
                else                         { $script:SCORE_NO_DATA }

    $p95Score = if ($null -ne $Row.P95)      { [double]$Row.P95 }
                elseif ($null -ne $Row.Max)  { [double]$Row.Max }
                elseif ($hasProto)           { $script:SCORE_PROTO_ONLY_P95 }
                else                         { $script:SCORE_NO_DATA }

    $protoBonus = 0
    if     ($Row.StratumPorts -and $Row.StratumPorts -ne "") { $protoBonus = -30 }
    elseif ($Row.HttpsPorts   -and $Row.HttpsPorts   -ne "") { $protoBonus = -10 }
    elseif ($Row.HttpPorts    -and $Row.HttpPorts    -ne "") { $protoBonus =   0 }
    else                                                     { $protoBonus = 150 }

    $score = ($lossScore * 10) + ($avgScore * 0.5) + ($jitScore * 0.3) + ($p95Score * 0.2) + $protoBonus
    return [Math]::Round($score, 2)
}

# ========================================================
# RANK ICONS
# ========================================================
function Get-RankColor {
    param([int]$Rank)
    switch ($Rank) {
        1 { return "Green" }
        2 { return "Cyan" }
        3 { return "Yellow" }
        default { return "White" }
    }
}

function Get-RankIcon {
    param([int]$Rank)
    if ($Rank -le 99) { return ("{0,2} " -f $Rank) } else { return "   " }
}
