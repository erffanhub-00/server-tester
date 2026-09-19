# ========================================================
# Server Tester - POWER EDITION  v2.0.0
# ========================================================
# Multi-protocol, multi-category network tester.
# Config-driven (categories.json). Cross-platform.
#
# Layered measurement model:
#   Layer 1 - ICMP latency    (network reachability)
#   Layer 2 - TCP connect     (transport reachability)
#   Layer 3 - Application     (HTTP/HTTPS/Stratum handshake)
#
# Every metric is measured independently. No metric is
# derived from another layer's timing.
# ========================================================

[CmdletBinding()]
param(
    [string]$CategoryName,
    [int]   $Packets,
    [string]$ConfigFile = "categories.json",
    [string]$OutputDir  = "output",
    [switch]$NoMenu
)

# ========================================================
# GLOBAL STATE
# ========================================================
$script:VERSION            = "2.0.0"
$script:MAX_PACKETS        = 500
$script:DEFAULT_PACKETS    = 20
$script:MIN_PACKETS        = 1

# Timeouts (ms)
$script:PING_TIMEOUT_MS    = 2000
$script:TCP_TIMEOUT_MS     = 3000
$script:APP_TIMEOUT_MS     = 5000
$script:MAX_BUFFER_BYTES   = 65536

# Concurrency
$script:MAX_WORKERS        = 20

# TLS validation default
$script:VALIDATE_TLS       = $false

# HTTP method
$script:HTTP_METHOD        = "HEAD"   # HEAD or GET
$script:HTTP_VERSION       = "1.1"    # 1.0 or 1.1

$script:PACKETS            = $script:DEFAULT_PACKETS

$script:RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $script:RootDir) { $script:RootDir = (Get-Location).Path }

$script:ConfigPath = if ([System.IO.Path]::IsPathRooted($ConfigFile)) {
    $ConfigFile
} else {
    Join-Path $script:RootDir $ConfigFile
}

$script:OutputPath = if ([System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir
} else {
    Join-Path $script:RootDir $OutputDir
}

if (-not (Test-Path $script:OutputPath)) {
    try { New-Item -ItemType Directory -Path $script:OutputPath -Force | Out-Null } catch {}
}

# ========================================================
# THEME
# ========================================================
$script:Theme = @{
    Primary     = "Cyan"
    Secondary   = "Magenta"
    Success     = "Green"
    Warning     = "Yellow"
    Danger      = "Red"
    Muted       = "DarkGray"
    Highlight   = "White"
    Border      = "DarkCyan"
    BorderHeavy = "Cyan"
    Accent      = "DarkYellow"
}

# ========================================================
# CLEANUP
# ========================================================
$script:ActivePool = $null

function Register-Cleanup {
    $existing = Get-EventSubscriber -SourceIdentifier "ServerTester.Cleanup" -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-Event -SourceIdentifier "ServerTester.Cleanup" -ErrorAction SilentlyContinue
    }
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -SupportEvent -Action {
        try {
            if ($script:ActivePool) {
                try { $script:ActivePool.Close()   } catch {}
                try { $script:ActivePool.Dispose() } catch {}
            }
            [GC]::Collect()
        } catch {}
    }
}

# ========================================================
# UI PRIMITIVES
# ========================================================
function Get-ConsoleWidth {
    try {
        $w = [Console]::WindowWidth
        if ($w -lt 60) { return 78 }
        if ($w -gt 130) { return 128 }
        return $w - 2
    } catch { return 78 }
}

function Write-BorderTop {
    param([string]$Title = "", [string]$Color = $script:Theme.BorderHeavy)
    $w = Get-ConsoleWidth
    if ([string]::IsNullOrEmpty($Title)) {
        Write-Host ("=" * $w) -ForegroundColor $Color
    } else {
        $pad = [Math]::Max(0, $w - $Title.Length - 4)
        $left = [Math]::Floor($pad / 2)
        $right = $pad - $left
        Write-Host ("=" * $left + "  " + $Title + "  " + "=" * $right) -ForegroundColor $Color
    }
}

function Write-BorderThin {
    param([string]$Color = $script:Theme.Border)
    $w = Get-ConsoleWidth
    Write-Host ("-" * $w) -ForegroundColor $Color
}

function Write-Banner {
    $w = Get-ConsoleWidth
    Write-Host ""
    Write-BorderTop
    $line1 = "SERVER TESTER"
    $line2 = "POWER EDITION  -  v$($script:VERSION)"
    $pad1 = [Math]::Max(0, [Math]::Floor(($w - $line1.Length) / 2))
    $pad2 = [Math]::Max(0, [Math]::Floor(($w - $line2.Length) / 2))
    Write-Host (" " * $pad1 + $line1) -ForegroundColor $script:Theme.Primary
    Write-Host (" " * $pad2 + $line2) -ForegroundColor $script:Theme.Muted
    Write-BorderTop
    Write-Host ""
}

function Show-Title {
    try { [Console]::Clear() } catch { try { Clear-Host } catch {} }
    Write-Banner
}

function Format-Ms {
    param($v)
    if ($null -eq $v) { return "N/A" }
    try { return ("{0:F1} ms" -f [double]$v) } catch { return "N/A" }
}

function Format-Pct {
    param($v)
    if ($null -eq $v) { return "N/A" }
    try { return ("{0:F1}%" -f [double]$v) } catch { return "N/A" }
}

function Get-StatusIcon {
    param([string]$Kind)
    switch ($Kind) {
        "ok"     { return "[+]" }
        "fail"   { return "[-]" }
        "warn"   { return "[!]" }
        "info"   { return "[i]" }
        "arrow"  { return " ->" }
        default  { return "   " }
    }
}

function Get-LatencyColor {
    param([double]$Ms)
    if ($Ms -le 50)  { return "Green" }
    if ($Ms -le 100) { return "Cyan" }
    if ($Ms -le 200) { return "Yellow" }
    if ($Ms -le 400) { return "DarkYellow" }
    return "Red"
}

function Get-LossColor {
    param([double]$Loss)
    if ($Loss -eq 0)   { return "Green" }
    if ($Loss -lt 5)   { return "Cyan" }
    if ($Loss -lt 25)  { return "Yellow" }
    if ($Loss -lt 75)  { return "DarkYellow" }
    return "Red"
}

# ========================================================
# CONFIG LOADING + STRICT VALIDATION
# ========================================================
function Load-Categories {
    if (-not (Test-Path $script:ConfigPath)) {
        Write-Host "Config not found: $($script:ConfigPath)" -ForegroundColor $script:Theme.Danger
        return $null
    }
    try {
        $raw = Get-Content -Path $script:ConfigPath -Raw -Encoding UTF8
        $obj = $raw | ConvertFrom-Json
        if (-not $obj) { throw "Empty config" }
        return $obj
    } catch {
        Write-Host "Failed to parse config: $($_.Exception.Message)" -ForegroundColor $script:Theme.Danger
        return $null
    }
}

function Get-CategoryNames {
    param($Categories)
    if (-not $Categories) { return @() }
    return @($Categories.PSObject.Properties.Name)
}

function ConvertTo-PortArray {
    param($Value, [string]$Field, [string]$CategoryKey)
    $result = @()
    if ($null -eq $Value) { return ,$result }
    if ($Value -is [array] -and $Value.Count -eq 0) { return ,$result }
    if ($Value -isnot [array]) { $Value = @($Value) }
    foreach ($v in $Value) {
        $n = 0
        if (-not [int]::TryParse("$v", [ref]$n)) {
            Write-Host "  [!] $CategoryKey / $Field : '$v' is not a number" -ForegroundColor $script:Theme.Danger
            return $null
        }
        if ($n -lt 1 -or $n -gt 65535) {
            Write-Host "  [!] $CategoryKey / $Field : $n out of range 1-65535" -ForegroundColor $script:Theme.Danger
            return $null
        }
        if ($result -notcontains $n) { $result += $n }
    }
    return ,$result
}

function Test-CategoryData {
    param($Cat, [string]$Key)
    $errors = @()

    if (-not $Cat.name)    { $errors += "missing 'name'" }
    if (-not $Cat.servers) { $errors += "missing 'servers'" }
    if ($Cat.servers -and @($Cat.servers).Count -eq 0) { $errors += "'servers' is empty" }
    if (-not $Cat.ports)   { $errors += "missing 'ports'" }

    if ($errors.Count -gt 0) {
        Write-Host "  [!] Category '$Key' : $($errors -join ', ')" -ForegroundColor $script:Theme.Danger
        return $false
    }

    $ports        = ConvertTo-PortArray $Cat.ports         "ports"         $Key
    $httpPorts    = ConvertTo-PortArray $Cat.http_ports    "http_ports"    $Key
    $httpsPorts   = ConvertTo-PortArray $Cat.https_ports   "https_ports"   $Key
    $stratumPorts = ConvertTo-PortArray $Cat.stratum_ports "stratum_ports" $Key

    if ($null -eq $ports) {
        return $false
    }

    # subset checks
    foreach ($p in $httpPorts)    { if ($ports -notcontains $p) { Write-Host "  [!] $Key : http_ports $p not in ports"    -ForegroundColor $script:Theme.Danger; return $false } }
    foreach ($p in $httpsPorts)   { if ($ports -notcontains $p) { Write-Host "  [!] $Key : https_ports $p not in ports"   -ForegroundColor $script:Theme.Danger; return $false } }
    foreach ($p in $stratumPorts) { if ($ports -notcontains $p) { Write-Host "  [!] $Key : stratum_ports $p not in ports" -ForegroundColor $script:Theme.Danger; return $false } }

    # overlap checks
    $allProto = @()
    foreach ($p in $httpPorts)    { $allProto += @{ port = $p; proto = "http" } }
    foreach ($p in $httpsPorts)   { $allProto += @{ port = $p; proto = "https" } }
    foreach ($p in $stratumPorts) { $allProto += @{ port = $p; proto = "stratum" } }
    $seen = @{}
    foreach ($item in $allProto) {
        if ($seen.ContainsKey($item.port)) {
            Write-Host "  [!] $Key : port $($item.port) is in both $($seen[$item.port]) and $($item.proto)" -ForegroundColor $script:Theme.Danger
            return $false
        }
        $seen[$item.port] = $item.proto
    }

    return $true
}

# ========================================================
# PACKETS PROMPT
# ========================================================
function Ask-Packets {
    while ($true) {
        Write-Host (Get-StatusIcon "arrow") -NoNewline -ForegroundColor $script:Theme.Accent
        Write-Host " Number of ping tests " -NoNewline
        Write-Host "($($script:MIN_PACKETS)-$($script:MAX_PACKETS))" -ForegroundColor $script:Theme.Muted -NoNewline
        Write-Host " [$($script:DEFAULT_PACKETS)]: " -NoNewline -ForegroundColor $script:Theme.Muted
        $p = Read-Host
        if ([string]::IsNullOrWhiteSpace($p)) {
            $script:PACKETS = $script:DEFAULT_PACKETS
            return
        }
        if ($p -notmatch '^\d+$') {
            Write-Host "  Enter a whole number." -ForegroundColor $script:Theme.Danger
            continue
        }
        $n = [int]$p
        if ($n -lt $script:MIN_PACKETS) {
            Write-Host "  Minimum $($script:MIN_PACKETS)." -ForegroundColor $script:Theme.Danger
            continue
        }
        if ($n -gt $script:MAX_PACKETS) {
            Write-Host "  Maximum $($script:MAX_PACKETS)." -ForegroundColor $script:Theme.Danger
            continue
        }
        $script:PACKETS = $n
        return
    }
}

# ========================================================
# WORKER SCRIPT
# ========================================================
$script:WorkerScript = {
    param(
        [string]$HostName,
        [string]$CategoryName,
        [int]   $Packets,
        [int[]] $Ports,
        [int[]] $HttpPorts,
        [int[]] $HttpsPorts,
        [int[]] $StratumPorts,
        [int]   $PingTimeoutMs,
        [int]   $TcpTimeoutMs,
        [int]   $AppTimeoutMs,
        [int]   $MaxBufferBytes,
        [bool]  $ValidateTls,
        [string]$HttpMethod,
        [string]$HttpVersion
    )

    # ------------------------------------------------
    # Helper: membership test (safe in runspace)
    # ------------------------------------------------
    function Test-InList {
        param([int]$Value, [int[]]$List)
        if (-not $List) { return $false }
        foreach ($item in $List) {
            if ([int]$item -eq [int]$Value) { return $true }
        }
        return $false
    }

    # ------------------------------------------------
    # DNS (returns both v4 and v6 info)
    # ------------------------------------------------
    function Resolve-IP {
        param([string]$Name)
        $out = [PSCustomObject]@{
            IPv4 = $null
            IPv6 = $null
            Primary = "N/A"
        }
        try {
            $all = [System.Net.Dns]::GetHostAddresses($Name)
            $v4 = $all | Where-Object { $_.AddressFamily -eq 'InterNetwork' }    | Select-Object -First 1
            $v6 = $all | Where-Object { $_.AddressFamily -eq 'InterNetworkV6' }  | Select-Object -First 1
            if ($v4) { $out.IPv4 = $v4.IPAddressToString }
            if ($v6) { $out.IPv6 = $v6.IPAddressToString }
            if     ($out.IPv4) { $out.Primary = $out.IPv4 }
            elseif ($out.IPv6) { $out.Primary = $out.IPv6 }
        } catch {}
        return $out
    }

    # ------------------------------------------------
    # LAYER 1 : ICMP
    # ------------------------------------------------
    function Measure-Icmp {
        param([string]$Name, [int]$Count, [int]$TimeoutMs)
        $samples = New-Object System.Collections.Generic.List[double]
        $failed  = 0
        $ping    = New-Object System.Net.NetworkInformation.Ping
        try {
            for ($i = 1; $i -le $Count; $i++) {
                try {
                    $reply = $ping.Send($Name, $TimeoutMs)
                    if ($reply -and $reply.Status -eq 'Success') {
                        $rtt = [double]$reply.RoundtripTime
                        if ($rtt -lt 1) { $rtt = 1 }
                        $samples.Add($rtt) | Out-Null
                    } else { $failed++ }
                } catch { $failed++ }
            }
        } finally { if ($ping) { try { $ping.Dispose() } catch {} } }
        return @{ Samples = $samples.ToArray(); Failed = $failed }
    }

    function Get-Percentile {
        param([double[]]$Values, [double]$P)
        if (-not $Values -or $Values.Count -eq 0) { return $null }
        $sorted = $Values | Sort-Object
        $idx = [Math]::Ceiling(($P / 100.0) * $sorted.Count) - 1
        if ($idx -lt 0) { $idx = 0 }
        if ($idx -ge $sorted.Count) { $idx = $sorted.Count - 1 }
        return [Math]::Round($sorted[$idx], 2)
    }

    # ------------------------------------------------
    # LAYER 2 : TCP connect
    # ------------------------------------------------
    function Measure-TcpConnect {
        param([string]$Name, [int]$Port, [int]$TimeoutMs)
        $client = $null
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect($Name, $Port, $null, $null)
            if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $null }
            try { $client.EndConnect($iar) } catch { return $null }
            if (-not $client.Connected) { return $null }
            $sw.Stop()
            return [Math]::Round($sw.Elapsed.TotalMilliseconds, 2)
        } catch { return $null }
        finally { if ($client) { try { $client.Close() } catch {} } }
    }

    # ------------------------------------------------
    # LAYER 3a : HTTP  (returns object with TcpTime + AppTime + Status)
    # ------------------------------------------------
    function Measure-Http {
        param([string]$Name, [int]$Port, [int]$TimeoutMs, [string]$Method, [string]$Version)

        $r = [PSCustomObject]@{
            TcpTime  = $null
            AppTime  = $null
            Status   = $null
            Ok       = $false
            Error    = $null
        }

        $client = $null
        try {
            $swTcp = [System.Diagnostics.Stopwatch]::StartNew()
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect($Name, $Port, $null, $null)
            if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
                $r.Error = "tcp timeout"; return $r
            }
            try { $client.EndConnect($iar) } catch { $r.Error = "tcp endconnect"; return $r }
            if (-not $client.Connected) { $r.Error = "tcp not connected"; return $r }
            $swTcp.Stop()
            $r.TcpTime = [Math]::Round($swTcp.Elapsed.TotalMilliseconds, 2)

            $stream = $client.GetStream()
            $stream.ReadTimeout  = $TimeoutMs
            $stream.WriteTimeout = $TimeoutMs

            $hostHeader = $Name
            $req = "$Method / HTTP/$Version`r`nHost: $hostHeader`r`nUser-Agent: ServerTester/$($Global:ST_VERSION)`r`nAccept: */*`r`nConnection: close`r`n`r`n"

            $swApp = [System.Diagnostics.Stopwatch]::StartNew()
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($req)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()

            $sb = New-Object System.Text.StringBuilder
            $buf = New-Object byte[] 2048
            $deadline = (Get-Date).AddMilliseconds($TimeoutMs)

            while ((Get-Date) -lt $deadline) {
                try {
                    $n = $stream.Read($buf, 0, $buf.Length)
                    if ($n -le 0) { break }
                    [void]$sb.Append([System.Text.Encoding]::ASCII.GetString($buf, 0, $n))
                    if ($sb.ToString() -match "`r`n`r`n") { break }
                    if ($sb.Length -gt 8192) { break }
                } catch { break }
            }
            $swApp.Stop()
            $r.AppTime = [Math]::Round($swApp.Elapsed.TotalMilliseconds, 2)

            $resp = $sb.ToString()
            if ($resp -match '^HTTP/\d\.\d\s+(\d{3})') {
                $r.Status = [int]$matches[1]
                $r.Ok = $true
            } else {
                $r.Error = "no valid status line"
            }
        } catch {
            $r.Error = $_.Exception.Message
        } finally {
            if ($client) { try { $client.Close() } catch {} }
        }
        return $r
    }

    # ------------------------------------------------
    # LAYER 3b : HTTPS  (same as HTTP + TLS)
    # ------------------------------------------------
    function Measure-Https {
        param([string]$Name, [int]$Port, [int]$TimeoutMs, [string]$Method, [string]$Version, [bool]$ValidateTls)

        $r = [PSCustomObject]@{
            TcpTime     = $null
            TlsTime     = $null
            AppTime     = $null
            TotalTime   = $null
            Status      = $null
            Ok          = $false
            TlsValid    = $null
            Error       = $null
        }

        $client = $null; $ssl = $null
        try {
            $swTcp = [System.Diagnostics.Stopwatch]::StartNew()
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect($Name, $Port, $null, $null)
            if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
                $r.Error = "tcp timeout"; return $r
            }
            try { $client.EndConnect($iar) } catch { $r.Error = "tcp endconnect"; return $r }
            if (-not $client.Connected) { $r.Error = "tcp not connected"; return $r }
            $swTcp.Stop()
            $r.TcpTime = [Math]::Round($swTcp.Elapsed.TotalMilliseconds, 2)

            $stream = $client.GetStream()

            if ($ValidateTls) {
                $cb = $null
            } else {
                $cb = [System.Net.Security.RemoteCertificateValidationCallback]{ param($a,$b,$c,$d) return $true }
            }
            $ssl = New-Object System.Net.Security.SslStream($stream, $false, $cb)
            $ssl.ReadTimeout  = $TimeoutMs
            $ssl.WriteTimeout = $TimeoutMs

            $swTls = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $ssl.AuthenticateAsClient($Name, $null, [System.Security.Authentication.SslProtocols]::None, $false)
                $swTls.Stop()
                $r.TlsTime = [Math]::Round($swTls.Elapsed.TotalMilliseconds, 2)
                $r.TlsValid = $true
            } catch {
                $swTls.Stop()
                $r.Error = "tls: $($_.Exception.Message)"
                if ($ValidateTls) { $r.TlsValid = $false }
                return $r
            }

            $hostHeader = $Name
            $req = "$Method / HTTP/$Version`r`nHost: $hostHeader`r`nUser-Agent: ServerTester/$($Global:ST_VERSION)`r`nAccept: */*`r`nConnection: close`r`n`r`n"

            $swApp = [System.Diagnostics.Stopwatch]::StartNew()
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($req)
            $ssl.Write($bytes, 0, $bytes.Length)
            $ssl.Flush()

            $sb = New-Object System.Text.StringBuilder
            $buf = New-Object byte[] 2048
            $deadline = (Get-Date).AddMilliseconds($TimeoutMs)

            while ((Get-Date) -lt $deadline) {
                try {
                    $n = $ssl.Read($buf, 0, $buf.Length)
                    if ($n -le 0) { break }
                    [void]$sb.Append([System.Text.Encoding]::ASCII.GetString($buf, 0, $n))
                    if ($sb.ToString() -match "`r`n`r`n") { break }
                    if ($sb.Length -gt 8192) { break }
                } catch { break }
            }
            $swApp.Stop()
            $r.AppTime = [Math]::Round($swApp.Elapsed.TotalMilliseconds, 2)
            $r.TotalTime = [Math]::Round([double]$r.TcpTime + [double]$r.TlsTime + [double]$r.AppTime, 2)

            $resp = $sb.ToString()
            if ($resp -match '^HTTP/\d\.\d\s+(\d{3})') {
                $r.Status = [int]$matches[1]
                $r.Ok = $true
            } else {
                $r.Error = "no valid status line"
            }
        } catch {
            $r.Error = $_.Exception.Message
        } finally {
            if ($ssl)    { try { $ssl.Close() }    catch {} }
            if ($client) { try { $client.Close() } catch {} }
        }
        return $r
    }

    # ------------------------------------------------
    # LAYER 3c : Stratum
    # ------------------------------------------------
    function Measure-Stratum {
        param([string]$Name, [int]$Port, [int]$TimeoutMs, [int]$MaxBuf)

        $r = [PSCustomObject]@{
            TcpTime  = $null
            AppTime  = $null
            Ok       = $false
            Error    = $null
            Response = $null
        }

        $client = $null
        try {
            $swTcp = [System.Diagnostics.Stopwatch]::StartNew()
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect($Name, $Port, $null, $null)
            if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
                $r.Error = "tcp timeout"; return $r
            }
            try { $client.EndConnect($iar) } catch { $r.Error = "tcp endconnect"; return $r }
            if (-not $client.Connected) { $r.Error = "tcp not connected"; return $r }
            $swTcp.Stop()
            $r.TcpTime = [Math]::Round($swTcp.Elapsed.TotalMilliseconds, 2)

            $stream = $client.GetStream()
            $stream.ReadTimeout  = $TimeoutMs
            $stream.WriteTimeout = $TimeoutMs

            $req = '{"id":1,"method":"mining.subscribe","params":["ServerTester/2.0"]}' + "`n"
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($req)

            $swApp = [System.Diagnostics.Stopwatch]::StartNew()
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()

            $buf      = New-Object byte[] 4096
            $sb       = New-Object System.Text.StringBuilder
            $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
            $done     = $false

            while ((Get-Date) -lt $deadline -and -not $done) {
                try {
                    $n = $stream.Read($buf, 0, $buf.Length)
                    if ($n -le 0) { break }
                    [void]$sb.Append([System.Text.Encoding]::ASCII.GetString($buf, 0, $n))
                    if ($sb.Length -gt $MaxBuf) { break }

                    $all = $sb.ToString()
                    $rxMatches = [regex]::Matches($all, '\{[^{}]*"id"\s*:\s*1\b[^{}]*\}')
                    foreach ($m in $rxMatches) {
                        try {
                            $obj = $m.Value | ConvertFrom-Json
                            if ($obj.PSObject.Properties.Name -contains 'error' -and $null -ne $obj.error) {
                                $r.Error = "stratum error"; $done = $true; break
                            }
                            if ($obj.PSObject.Properties.Name -contains 'result' -and $null -ne $obj.result) {
                                $r.Ok = $true
                                $r.Response = $m.Value
                                $done = $true; break
                            }
                        } catch {}
                    }
                } catch [System.IO.IOException] {
                    Start-Sleep -Milliseconds 100
                    continue
                } catch { break }
            }
            $swApp.Stop()
            $r.AppTime = [Math]::Round($swApp.Elapsed.TotalMilliseconds, 2)
        } catch {
            $r.Error = $_.Exception.Message
        } finally {
            if ($client) { try { $client.Close() } catch {} }
        }
        return $r
    }

    # ================================================
    # MAIN WORKER FLOW
    # ================================================
    $Global:ST_VERSION = "2.0.0"
    $dns = Resolve-IP $HostName

    # LAYER 1 : ICMP
    $icmp = Measure-Icmp -Name $HostName -Count $Packets -TimeoutMs $PingTimeoutMs
    $icmpArr = $icmp.Samples
    $icmpFailed = $icmp.Failed
    $icmpSuccess = $icmpArr.Count

    $icmpAvg = if ($icmpSuccess -gt 0) { [Math]::Round((($icmpArr | Measure-Object -Average).Average), 2) } else { $null }
    $icmpMin = if ($icmpArr.Count -gt 0) { ($icmpArr | Measure-Object -Minimum).Minimum } else { $null }
    $icmpMax = if ($icmpArr.Count -gt 0) { ($icmpArr | Measure-Object -Maximum).Maximum } else { $null }
    $icmpP50 = Get-Percentile $icmpArr 50
    $icmpP95 = Get-Percentile $icmpArr 95
    $icmpP99 = Get-Percentile $icmpArr 99
    $icmpStd = if ($icmpArr.Count -gt 1) {
        $m = ($icmpArr | Measure-Object -Average).Average
        $var = ($icmpArr | ForEach-Object { [Math]::Pow($_ - $m, 2) } | Measure-Object -Sum).Sum / ($icmpArr.Count - 1)
        [Math]::Round([Math]::Sqrt($var), 2)
    } else { $null }
    $icmpJit = $null
    if ($icmpArr.Count -gt 1) {
        $sum = 0.0
        for ($i = 1; $i -lt $icmpArr.Count; $i++) {
            $sum += [Math]::Abs($icmpArr[$i] - $icmpArr[$i - 1])
        }
        $icmpJit = [Math]::Round($sum / ($icmpArr.Count - 1), 2)
    }
    $icmpLoss = if ($Packets -gt 0) { [Math]::Round(($icmpFailed / $Packets) * 100, 1) } else { 0.0 }

    # LAYER 2 + 3 : Per-port
    $portResults = @{}

    foreach ($p in $Ports) {
        $entry = [PSCustomObject]@{
            Port          = $p
            TcpTime       = $null
            Protocol      = "tcp"
            ProtocolOk    = $false
            ProtocolTime  = $null
            Status        = $null
            Error         = $null
            TlsValid      = $null
        }

        if (Test-InList -Value $p -List $StratumPorts) {
            $entry.Protocol = "stratum"
            $r = Measure-Stratum -Name $HostName -Port $p -TimeoutMs $AppTimeoutMs -MaxBuf $MaxBufferBytes
            $entry.TcpTime      = $r.TcpTime
            $entry.ProtocolTime = $r.AppTime
            $entry.ProtocolOk   = $r.Ok
            $entry.Error        = $r.Error

        } elseif (Test-InList -Value $p -List $HttpsPorts) {
            $entry.Protocol = "https"
            $r = Measure-Https -Name $HostName -Port $p -TimeoutMs $AppTimeoutMs -Method $HttpMethod -Version $HttpVersion -ValidateTls $ValidateTls
            $entry.TcpTime      = $r.TcpTime
            $entry.ProtocolTime = $r.TotalTime
            $entry.ProtocolOk   = $r.Ok
            $entry.Status       = $r.Status
            $entry.Error        = $r.Error
            $entry.TlsValid     = $r.TlsValid

        } elseif (Test-InList -Value $p -List $HttpPorts) {
            $entry.Protocol = "http"
            $r = Measure-Http -Name $HostName -Port $p -TimeoutMs $AppTimeoutMs -Method $HttpMethod -Version $HttpVersion
            $entry.TcpTime      = $r.TcpTime
            $entry.ProtocolTime = $r.AppTime
            $entry.ProtocolOk   = $r.Ok
            $entry.Status       = $r.Status
            $entry.Error        = $r.Error

        } else {
            # TCP only
            $entry.Protocol = "tcp"
            $entry.TcpTime  = Measure-TcpConnect -Name $HostName -Port $p -TimeoutMs $TcpTimeoutMs
        }

        $portResults[$p] = $entry
    }

    # ------------------------------------------------
    # Aggregate
    # ------------------------------------------------
    $tcpOpenList   = @()
    $stratumOkList = @()
    $httpOkList    = @()
    $httpsOkList   = @()

    foreach ($p in $Ports) {
        $e = $portResults[$p]
        if ($null -ne $e.TcpTime) { $tcpOpenList += $p }
        if ($e.ProtocolOk) {
            switch ($e.Protocol) {
                "stratum" { $stratumOkList += $p }
                "http"    { $httpOkList    += $p }
                "https"   { $httpsOkList   += $p }
            }
        }
    }

    # Best port - use application-level time
    $bestPort = ""
    $bestTime = [double]::MaxValue
    foreach ($p in $Ports) {
        $e = $portResults[$p]
        if ($e.ProtocolOk -and $null -ne $e.ProtocolTime) {
            if ([double]$e.ProtocolTime -lt $bestTime) {
                $bestTime = [double]$e.ProtocolTime
                $bestPort = "$p"
            }
        }
    }

    # Serialize portResults into flat strings for CSV
    $portDetail = @()
    foreach ($p in $Ports) {
        $e = $portResults[$p]
        $tcpStr = if ($null -eq $e.TcpTime)      { "-" } else { "{0:F1}" -f $e.TcpTime }
        $appStr = if ($null -eq $e.ProtocolTime) { "-" } else { "{0:F1}" -f $e.ProtocolTime }
        $stStr  = if ($null -eq $e.Status)       { "" }  else { " [HTTP $($e.Status)]" }
        $okStr  = if ($e.ProtocolOk)             { "OK" } else { "FAIL" }
        $portDetail += "${p}:$($e.Protocol):${tcpStr}ms:${appStr}ms:$okStr$stStr"
    }

    return [PSCustomObject]@{
        Host              = $HostName
        Category          = $CategoryName
        IP                = $dns.Primary
        IPv4              = $dns.IPv4
        IPv6              = $dns.IPv6

        # Layer 1 - ICMP
        IcmpSuccess       = $icmpSuccess
        IcmpFailed        = $icmpFailed
        IcmpLoss          = $icmpLoss
        IcmpAvg           = $icmpAvg
        IcmpMin           = $icmpMin
        IcmpMax           = $icmpMax
        IcmpP50           = $icmpP50
        IcmpP95           = $icmpP95
        IcmpP99           = $icmpP99
        IcmpJitter        = $icmpJit
        IcmpStdDev        = $icmpStd

        # Layer 2 - TCP
        TcpOpenPorts      = ($tcpOpenList -join ",")

        # Layer 3 - Application
        StratumPorts      = ($stratumOkList -join ",")
        HttpPorts         = ($httpOkList    -join ",")
        HttpsPorts        = ($httpsOkList   -join ",")

        BestPort          = $bestPort
        PortDetails       = ($portDetail -join " | ")

        # For backward-compatible display
        Loss              = $icmpLoss
        Avg               = $icmpAvg
        Min               = $icmpMin
        Max               = $icmpMax
        P50               = $icmpP50
        P95               = $icmpP95
        P99               = $icmpP99
        Jitter            = $icmpJit
        StdDev            = $icmpStd
        Success           = $icmpSuccess
        Failed            = $icmpFailed
        OpenPorts         = ($tcpOpenList -join ",")
    }
}

# ========================================================
# SCORING
# ========================================================
function Get-Score {
    param($Row)

    $lossScore = [double]$Row.Loss

    $hasProto = ($Row.StratumPorts -and $Row.StratumPorts -ne "") -or
                ($Row.HttpsPorts   -and $Row.HttpsPorts   -ne "") -or
                ($Row.HttpPorts    -and $Row.HttpPorts    -ne "")

    $avgScore = if ($null -ne $Row.Avg)      { [double]$Row.Avg }
                elseif ($hasProto)           { 500.0 }
                else                         { 9999.0 }

    $jitScore = if ($null -ne $Row.Jitter)   { [double]$Row.Jitter }
                elseif ($hasProto)           { 100.0 }
                else                         { 9999.0 }

    $p95Score = if ($null -ne $Row.P95)      { [double]$Row.P95 }
                elseif ($null -ne $Row.Max)  { [double]$Row.Max }
                elseif ($hasProto)           { 500.0 }
                else                         { 9999.0 }

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

# ========================================================
# RANKING + EXPORT
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

    $hdr = "{0,-4}{1,-24}{2,8}{3,10}{4,10}{5,10}  {6,-16}{7,8}" -f `
        "#","SERVER","LOSS","AVG","P95","JITTER","PROTO","SCORE"
    Write-Host "  " -NoNewline
    Write-Host $hdr -ForegroundColor $script:Theme.Muted
    Write-BorderThin

    $rank = 1
    foreach ($r in $scored) {
        $rankColor = Get-RankColor $rank
        $lossColor = Get-LossColor $r.Loss

        $avgStr = if ($null -eq $r.Avg)    { "N/A" } else { "{0:F1}ms" -f $r.Avg }
        $p95Str = if ($null -eq $r.P95)    { "N/A" } else { "{0:F1}ms" -f $r.P95 }
        $jitStr = if ($null -eq $r.Jitter) { "N/A" } else { "{0:F1}ms" -f $r.Jitter }

        $proto = "no"
        if     ($r.StratumPorts -and $r.StratumPorts -ne "") { $proto = "Stratum:$($r.BestPort)" }
        elseif ($r.HttpsPorts   -and $r.HttpsPorts   -ne "") { $proto = "HTTPS:$($r.BestPort)" }
        elseif ($r.HttpPorts    -and $r.HttpPorts    -ne "") { $proto = "HTTP:$($r.BestPort)" }
        if ($proto.Length -gt 15) { $proto = $proto.Substring(0,15) }

        $avgColor = "White"
        if ($null -ne $r.Avg) { $avgColor = Get-LatencyColor ([double]$r.Avg) }

        Write-Host "  " -NoNewline
        Write-Host (Get-RankIcon $rank) -ForegroundColor $rankColor -NoNewline
        Write-Host ("{0,-24}" -f $r.Host) -NoNewline
        Write-Host ("{0,8:F1}%" -f $r.Loss) -ForegroundColor $lossColor -NoNewline
        Write-Host ("{0,10}" -f $avgStr) -ForegroundColor $avgColor -NoNewline
        Write-Host ("{0,10}" -f $p95Str) -ForegroundColor $script:Theme.Warning -NoNewline
        Write-Host ("{0,10}" -f $jitStr) -ForegroundColor $script:Theme.Secondary -NoNewline
        Write-Host "  " -NoNewline
        Write-Host ("{0,-15}" -f $proto) -ForegroundColor $script:Theme.Accent -NoNewline
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

    # ---------- CSV ----------
    $ts      = Get-Date -Format 'yyyyMMdd_HHmmss'
    $csvName = "server_tester_${CategoryKey}_${ts}.csv"
    $csv     = Join-Path $script:OutputPath $csvName
    $jsonName = "server_tester_${CategoryKey}_${ts}.json"
    $json     = Join-Path $script:OutputPath $jsonName

    try {
        $scored | Select-Object `
            Host, Category, IP, IPv4, IPv6,
            IcmpSuccess, IcmpFailed, IcmpLoss,
            IcmpAvg, IcmpMin, IcmpMax, IcmpP50, IcmpP95, IcmpP99,
            IcmpJitter, IcmpStdDev,
            TcpOpenPorts,
            StratumPorts, HttpPorts, HttpsPorts,
            BestPort, PortDetails, Score |
            Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
        Write-Host "  " -NoNewline
        Write-Host "[CSV]  " -ForegroundColor $script:Theme.Success -NoNewline
        Write-Host $csv -ForegroundColor $script:Theme.Muted
    } catch {
        Write-Host "  [ERR] CSV: $($_.Exception.Message)" -ForegroundColor $script:Theme.Danger
    }

    try {
        $scored | Select-Object `
            Host, Category, IP, IPv4, IPv6,
            IcmpSuccess, IcmpFailed, IcmpLoss,
            IcmpAvg, IcmpMin, IcmpMax, IcmpP50, IcmpP95, IcmpP99,
            IcmpJitter, IcmpStdDev,
            TcpOpenPorts,
            StratumPorts, HttpPorts, HttpsPorts,
            BestPort, PortDetails, Score |
            ConvertTo-Json -Depth 5 |
            Set-Content -Path $json -Encoding UTF8
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
    param($r, [int[]]$Ports, [int[]]$HttpPorts, [int[]]$HttpsPorts, [int[]]$StratumPorts)

    Write-Host ""
    Write-BorderThin
    Write-Host "  " -NoNewline
    Write-Host "HOST  " -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host $r.Host -ForegroundColor $script:Theme.Primary
    Write-BorderThin

    Write-Host "  " -NoNewline
    Write-Host "IP          " -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host ("{0,-24}" -f $r.IP) -ForegroundColor $script:Theme.Highlight -NoNewline
    Write-Host "Category    " -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host $r.Category

    Write-Host "  " -NoNewline
    Write-Host "Success     " -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host ("{0,-24}" -f $r.Success) -ForegroundColor $script:Theme.Success -NoNewline
    Write-Host "Failed      " -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host $r.Failed -ForegroundColor $script:Theme.Danger

    Write-Host "  " -NoNewline
    Write-Host "Packet Loss " -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host ("{0,-24}" -f (Format-Pct $r.Loss)) -ForegroundColor (Get-LossColor $r.Loss) -NoNewline
    Write-Host "Jitter      " -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host (Format-Ms $r.Jitter) -ForegroundColor $script:Theme.Secondary

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

    # Re-parse PortDetails for the display
    $detailsMap = @{}
    if ($r.PortDetails) {
        foreach ($segment in ($r.PortDetails -split " \| ")) {
            $parts = $segment -split ":"
            if ($parts.Count -ge 5) {
                $portNum = $parts[0]
                $detailsMap[$portNum] = @{
                    protocol = $parts[1]
                    tcp      = $parts[2]
                    app      = $parts[3]
                    state    = $parts[4]
                }
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
                $tcpStr = ("{0,7} ms" -f $d.tcp)
                $appStr = if ($d.app -ne "-") { ("  app {0,7} ms" -f $d.app) } else { "" }

                Write-Host ("  {0,-6}" -f $p) -ForegroundColor $script:Theme.Highlight -NoNewline
                Write-Host " OPEN  " -ForegroundColor $script:Theme.Success -NoNewline
                Write-Host ("tcp{0}" -f $tcpStr) -ForegroundColor $script:Theme.Muted -NoNewline
                Write-Host $appStr -ForegroundColor $script:Theme.Muted -NoNewline
                Write-Host "  $protoTag " -ForegroundColor $script:Theme.Primary -NoNewline
                Write-Host "$($d.state)" -ForegroundColor $stateColor
            }
        } else {
            Write-Host ("  {0,-6}" -f $p) -ForegroundColor $script:Theme.Highlight -NoNewline
            Write-Host " CLOSED" -ForegroundColor $script:Theme.Danger
        }
    }
    Write-BorderThin
}

# ========================================================
# CATEGORY TEST
# ========================================================
function Start-CategoryTest {
    param(
        [string]$CategoryKey,
        $CategoryData,
        [int]$Packets
    )

    if (-not (Test-CategoryData $CategoryData $CategoryKey)) {
        Write-Host "Skipping category '$CategoryKey'." -ForegroundColor $script:Theme.Warning
        Start-Sleep 2
        return
    }

    $servers      = @($CategoryData.servers)
    $ports        = ConvertTo-PortArray $CategoryData.ports        "ports"         $CategoryKey
    $httpPorts    = ConvertTo-PortArray $CategoryData.http_ports   "http_ports"    $CategoryKey
    $httpsPorts   = ConvertTo-PortArray $CategoryData.https_ports  "https_ports"   $CategoryKey
    $stratumPorts = ConvertTo-PortArray $CategoryData.stratum_ports "stratum_ports" $CategoryKey

    try { [Console]::Clear() } catch {}
    Write-Banner
    Write-Host "  " -NoNewline
    Write-Host "CATEGORY  " -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host $CategoryData.name -ForegroundColor $script:Theme.Primary
    Write-BorderThin
    Write-Host "  " -NoNewline
    Write-Host "Key       " -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host $CategoryKey
    Write-Host "  " -NoNewline
    Write-Host "Servers   " -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host $servers.Count
    Write-Host "  " -NoNewline
    Write-Host "Packets   " -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host $Packets
    Write-Host "  " -NoNewline
    Write-Host "Workers   " -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host ("{0} (max)" -f [Math]::Min($script:MAX_WORKERS, [Math]::Max(2, $servers.Count)))
    Write-Host "  " -NoNewline
    Write-Host "Ports     " -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host ($ports -join ', ') -ForegroundColor $script:Theme.Accent
    Write-Host ""

    if ($servers.Count -eq 0) {
        Write-Host "  No servers in this category." -ForegroundColor $script:Theme.Warning
        Read-Host "  Press Enter to continue" | Out-Null
        return
    }

    Write-Host "  " -NoNewline
    Write-Host "Testing in parallel ..." -ForegroundColor $script:Theme.Warning
    Write-Host ""

    $pool    = $null
    $handles = @()
    $results = New-Object System.Collections.Generic.List[object]

    $maxWorkers = [Math]::Min($script:MAX_WORKERS, [Math]::Max(2, $servers.Count))

    try {
        $pool = [runspacefactory]::CreateRunspacePool(1, $maxWorkers)
        $pool.Open()
        $script:ActivePool = $pool

        foreach ($s in $servers) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($script:WorkerScript).
                AddParameter("HostName",       $s).
                AddParameter("CategoryName",   $CategoryKey).
                AddParameter("Packets",        $Packets).
                AddParameter("Ports",          [int[]]$ports).
                AddParameter("HttpPorts",      [int[]]$httpPorts).
                AddParameter("HttpsPorts",     [int[]]$httpsPorts).
                AddParameter("StratumPorts",   [int[]]$stratumPorts).
                AddParameter("PingTimeoutMs",  $script:PING_TIMEOUT_MS).
                AddParameter("TcpTimeoutMs",   $script:TCP_TIMEOUT_MS).
                AddParameter("AppTimeoutMs",   $script:APP_TIMEOUT_MS).
                AddParameter("MaxBufferBytes", $script:MAX_BUFFER_BYTES).
                AddParameter("ValidateTls",    $script:VALIDATE_TLS).
                AddParameter("HttpMethod",     $script:HTTP_METHOD).
                AddParameter("HttpVersion",    $script:HTTP_VERSION)

            $handles += [PSCustomObject]@{
                Host   = $s
                PS     = $ps
                Handle = $ps.BeginInvoke()
                Done   = $false
                Stopped = $false
            }
        }

        $total = $handles.Count
        $done  = 0
        $maxWaitSec   = ($Packets * 2) + ($ports.Count * 12) + 60
        $hardDeadline = (Get-Date).AddSeconds($maxWaitSec)
        $showProgress = ($total -ge 2)

        while ($done -lt $total -and (Get-Date) -lt $hardDeadline) {
            foreach ($h in $handles) {
                if ($h.Done) { continue }
                $state = $h.PS.InvocationStateInfo.State
                if ($state -in @('Completed','Failed','Stopped','Disconnected')) {
                    $h.Done = $true
                    $done++
                    if ($showProgress) {
                        $pct = [int](100 * $done / $total)
                        Write-Progress -Activity "Testing $($CategoryData.name)" `
                                       -Status "$done / $total servers" `
                                       -PercentComplete $pct
                    }
                }
            }
            if ($done -lt $total) { Start-Sleep -Milliseconds 150 }
        }

        # HARD STOP remaining workers
        if ($done -lt $total) {
            Write-Host "  [!] Hard timeout reached. Stopping remaining workers." -ForegroundColor $script:Theme.Warning
            foreach ($h in $handles) {
                if (-not $h.Done) {
                    try { $h.PS.Stop() } catch {}
                    $h.Stopped = $true
                    $h.Done = $true
                }
            }
        }
        if ($showProgress) { Write-Progress -Activity "Testing" -Completed }

        foreach ($h in $handles) {
            try {
                if ($h.Stopped) { continue }
                $res = $h.PS.EndInvoke($h.Handle)
                foreach ($r in $res) {
                    if ($null -ne $r) { $results.Add($r) | Out-Null }
                }
            } catch {
                Write-Host "  [ERR] $($h.Host): $($_.Exception.Message)" -ForegroundColor $script:Theme.Danger
            } finally {
                try { $h.PS.Dispose() } catch {}
            }
        }
    }
    finally {
        if ($pool) {
            try { $pool.Close() }    catch {}
            try { $pool.Dispose() }  catch {}
        }
        $script:ActivePool = $null
    }

    $ordered = @()
    foreach ($s in $servers) {
        $match = $results | Where-Object { $_.Host -eq $s } | Select-Object -First 1
        if ($match) { $ordered += $match }
    }
    $seenHosts = @($ordered | ForEach-Object { $_.Host })
    foreach ($r in $results) {
        if ($r.Host -notin $seenHosts) { $ordered += $r }
    }

    try { [Console]::Clear() } catch {}
    Write-Banner
    Write-Host "  " -NoNewline
    Write-Host "RESULTS  " -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host "$($CategoryData.name)" -ForegroundColor $script:Theme.Primary
    Write-BorderTop -Color $script:Theme.Border

    foreach ($r in $ordered) {
        Show-ServerDetail -r $r -Ports $ports -HttpPorts $httpPorts -HttpsPorts $httpsPorts -StratumPorts $stratumPorts
    }

    Show-Ranking -Results $ordered -CategoryKey $CategoryKey

    Write-Host ""
    Read-Host "  Press Enter to continue" | Out-Null
}

# ========================================================
# CATEGORY VIEWER
# ========================================================
function Show-CategoryDetails {
    param($Categories, [string]$Key)
    $cat = $Categories.$Key
    if (-not $cat) { return }

    Write-BorderThin
    Write-Host "  " -NoNewline
    Write-Host ("{0,-20}" -f $Key) -ForegroundColor $script:Theme.Accent -NoNewline
    Write-Host $cat.name -ForegroundColor $script:Theme.Primary

    if ($cat.description) {
        Write-Host "  " -NoNewline
        Write-Host ("{0,-20}" -f "") -NoNewline
        Write-Host $cat.description -ForegroundColor $script:Theme.Muted
    }
    if ($cat.servers) {
        Write-Host "  " -NoNewline
        Write-Host ("{0,-20}" -f "Servers:") -ForegroundColor $script:Theme.Muted -NoNewline
        Write-Host "$(@($cat.servers).Count) host(s)" -ForegroundColor $script:Theme.Highlight
    }
    if ($cat.ports) {
        Write-Host "  " -NoNewline
        Write-Host ("{0,-20}" -f "Ports:") -ForegroundColor $script:Theme.Muted -NoNewline
        Write-Host ($cat.ports -join ', ') -ForegroundColor $script:Theme.Highlight
    }
    if ($cat.stratum_ports) {
        Write-Host "  " -NoNewline
        Write-Host ("{0,-20}" -f "Stratum:") -ForegroundColor $script:Theme.Muted -NoNewline
        Write-Host ($cat.stratum_ports -join ', ') -ForegroundColor $script:Theme.Success
    }
    if ($cat.http_ports) {
        Write-Host "  " -NoNewline
        Write-Host ("{0,-20}" -f "HTTP:") -ForegroundColor $script:Theme.Muted -NoNewline
        Write-Host ($cat.http_ports -join ', ') -ForegroundColor $script:Theme.Primary
    }
    if ($cat.https_ports) {
        Write-Host "  " -NoNewline
        Write-Host ("{0,-20}" -f "HTTPS:") -ForegroundColor $script:Theme.Muted -NoNewline
        Write-Host ($cat.https_ports -join ', ') -ForegroundColor $script:Theme.Primary
    }
}

# ========================================================
# CATEGORY PICKER
# ========================================================
function Pick-Category {
    param($Categories)
    while ($true) {
        try { [Console]::Clear() } catch {}
        Write-Banner

        $names = @(Get-CategoryNames $Categories)
        if ($names.Count -eq 0) {
            Write-Host "  No categories in config." -ForegroundColor $script:Theme.Danger
            Read-Host "  Press Enter to continue" | Out-Null
            return $null
        }

        Write-Host "  " -NoNewline
        Write-Host "AVAILABLE CATEGORIES" -ForegroundColor $script:Theme.Primary
        Write-BorderThin

        $i = 1
        foreach ($n in $names) {
            $cat = $Categories.$n
            $srvCount = if ($cat.servers) { @($cat.servers).Count } else { 0 }
            Write-Host "  " -NoNewline
            Write-Host ("{0,2})" -f $i) -ForegroundColor $script:Theme.Accent -NoNewline
            Write-Host " " -NoNewline
            Write-Host ("{0,-18}" -f $n) -ForegroundColor $script:Theme.Primary -NoNewline
            Write-Host ("{0,-30}" -f $cat.name) -NoNewline
            Write-Host ("[{0} srvs]" -f $srvCount) -ForegroundColor $script:Theme.Muted
            $i++
        }

        Write-Host ""
        Write-BorderThin
        Write-Host "  " -NoNewline
        Write-Host "SELECTION  " -ForegroundColor $script:Theme.Muted -NoNewline
        Write-Host "single: " -NoNewline -ForegroundColor $script:Theme.Muted
        Write-Host "1" -ForegroundColor $script:Theme.Accent -NoNewline
        Write-Host "  |  multi: " -NoNewline -ForegroundColor $script:Theme.Muted
        Write-Host "1,3,5" -ForegroundColor $script:Theme.Accent -NoNewline
        Write-Host "  |  range: " -NoNewline -ForegroundColor $script:Theme.Muted
        Write-Host "1-3" -ForegroundColor $script:Theme.Accent -NoNewline
        Write-Host "  |  all: " -NoNewline -ForegroundColor $script:Theme.Muted
        Write-Host "A" -ForegroundColor $script:Theme.Success -NoNewline
        Write-Host "  |  back: " -NoNewline -ForegroundColor $script:Theme.Muted
        Write-Host "0" -ForegroundColor $script:Theme.Muted
        Write-Host ""

        Write-Host (Get-StatusIcon "arrow") -NoNewline -ForegroundColor $script:Theme.Accent
        Write-Host " Select category: " -NoNewline
        $sel = Read-Host

        if ([string]::IsNullOrWhiteSpace($sel)) { continue }
        if ($sel.Trim() -eq "0") { return $null }
        if ($sel -match '^(?i)a$') { return "ALL" }

        $selectedKeys = @()
        $parts = $sel -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        $invalid = $false
        foreach ($part in $parts) {
            if ($part -match '^(\d+)-(\d+)$') {
                $from = [int]$matches[1]; $to = [int]$matches[2]
                if ($from -gt $to) { $tmp = $from; $from = $to; $to = $tmp }
                for ($j = $from; $j -le $to; $j++) {
                    if ($j -ge 1 -and $j -le $names.Count) {
                        $key = $names[$j - 1]
                        if ($key -notin $selectedKeys) { $selectedKeys += $key }
                    } else { $invalid = $true }
                }
            } elseif ($part -match '^\d+$') {
                $idx = [int]$part
                if ($idx -ge 1 -and $idx -le $names.Count) {
                    $key = $names[$idx - 1]
                    if ($key -notin $selectedKeys) { $selectedKeys += $key }
                } else { $invalid = $true }
            } else { $invalid = $true }
        }

        if ($invalid) {
            Write-Host "  [!] Invalid selection: $sel" -ForegroundColor $script:Theme.Danger
            Start-Sleep 1
            continue
        }
        if ($selectedKeys.Count -eq 0) {
            Write-Host "  [!] No category selected." -ForegroundColor $script:Theme.Danger
            Start-Sleep 1
            continue
        }
        return $selectedKeys
    }
}

# ========================================================
# MAIN MENU
# ========================================================
function Show-MainMenu {
    Show-Title
    Write-Host "  " -NoNewline
    Write-Host "MAIN MENU" -ForegroundColor $script:Theme.Primary
    Write-BorderThin

    $items = @(
        @{ Key = "1"; Label = "Run test";           Desc = "Test servers in a category";  Color = $script:Theme.Success }
        @{ Key = "2"; Label = "Browse categories";  Desc = "View all categories";         Color = $script:Theme.Primary }
        @{ Key = "3"; Label = "Reload config";      Desc = "Reload categories.json";      Color = $script:Theme.Accent }
        @{ Key = "0"; Label = "Exit";               Desc = "Quit the tester";             Color = $script:Theme.Muted }
    )

    foreach ($it in $items) {
        Write-Host "  " -NoNewline
        Write-Host (" [{0}] " -f $it.Key) -ForegroundColor $it.Color -NoNewline
        Write-Host ("{0,-22}" -f $it.Label) -ForegroundColor $script:Theme.Highlight -NoNewline
        Write-Host $it.Desc -ForegroundColor $script:Theme.Muted
    }
    Write-Host ""
    Write-BorderThin
    Write-Host ""
}

function Main-Menu {
    $categories = Load-Categories
    if (-not $categories) {
        Write-Host "Cannot proceed without valid config." -ForegroundColor $script:Theme.Danger
        return
    }

    while ($true) {
        Show-MainMenu
        Write-Host (Get-StatusIcon "arrow") -NoNewline -ForegroundColor $script:Theme.Accent
        Write-Host " Select option: " -NoNewline
        $opt = Read-Host

        switch ($opt) {
            "1" {
                $sel = Pick-Category $categories
                if (-not $sel) { continue }

                try { [Console]::Clear() } catch {}
                Write-Banner
                Write-Host "  " -NoNewline
                Write-Host "SELECTION  " -ForegroundColor $script:Theme.Muted -NoNewline
                if ($sel -eq "ALL") {
                    Write-Host "ALL categories" -ForegroundColor $script:Theme.Primary
                } else {
                    Write-Host ($sel -join ", ") -ForegroundColor $script:Theme.Primary
                }
                Write-BorderThin
                Write-Host ""
                Ask-Packets

                if ($sel -eq "ALL") {
                    foreach ($k in (Get-CategoryNames $categories)) {
                        Start-CategoryTest -CategoryKey $k -CategoryData $categories.$k -Packets $script:PACKETS
                    }
                } else {
                    foreach ($k in $sel) {
                        Start-CategoryTest -CategoryKey $k -CategoryData $categories.$k -Packets $script:PACKETS
                    }
                }
            }
            "2" {
                Show-Title
                Write-Host "  " -NoNewline
                Write-Host "CATEGORIES" -ForegroundColor $script:Theme.Primary
                foreach ($k in (Get-CategoryNames $categories)) {
                    Show-CategoryDetails $categories $k
                }
                Write-Host ""
                Write-BorderTop -Color $script:Theme.Primary
                Write-Host ""
                Read-Host "  Press Enter to continue" | Out-Null
            }
            "3" {
                $categories = Load-Categories
                if ($categories) {
                    Write-Host "  [+] Config reloaded." -ForegroundColor $script:Theme.Success
                }
                Start-Sleep -Milliseconds 800
            }
            "0" {
                try { [Console]::Clear() } catch {}
                Write-Host ""
                Write-Host "  " -NoNewline
                Write-Host "Goodbye." -ForegroundColor $script:Theme.Success
                Write-Host ""
                return
            }
            default {
                Write-Host "  [!] Invalid option." -ForegroundColor $script:Theme.Danger
                Start-Sleep -Milliseconds 800
            }
        }
    }
}

# ========================================================
# ENTRY POINT
# ========================================================
Register-Cleanup

if ($NoMenu -and $CategoryName) {
    $categories = Load-Categories
    if (-not $categories) { exit 1 }
    if (-not $Packets -or $Packets -lt 1) { $Packets = $script:DEFAULT_PACKETS }
    if ($Packets -gt $script:MAX_PACKETS) { $Packets = $script:MAX_PACKETS }
    if (-not $categories.$CategoryName) {
        Write-Host "Category not found: $CategoryName" -ForegroundColor $script:Theme.Danger
        exit 1
    }
    Start-CategoryTest -CategoryKey $CategoryName -CategoryData $categories.$CategoryName -Packets $Packets
    exit 0
}

Main-Menu