# ========================================================
# Server Tester - Worker
# ========================================================
# Parallel measurement worker (ICMP/TCP/HTTP/HTTPS/Stratum).
# Part of ServerTester.ps1. Dot-sourced by the entry script;
# do not run directly.

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
        [string]$HttpVersion,
        [string]$ToolVersion
    )

    function Test-InList {
        param([int]$Value, [int[]]$List)
        if (-not $List) { return $false }
        foreach ($item in $List) {
            if ([int]$item -eq [int]$Value) { return $true }
        }
        return $false
    }

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
        } catch {
            # DNS failure is not fatal: the server is still tested by
            # name and reported with IP "N/A".
        }
        return $out
    }

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

    function Measure-Http {
        param([string]$Name, [int]$Port, [int]$TimeoutMs, [string]$Method, [string]$Version, [string]$ToolVersion)

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
            $req = "$Method / HTTP/$Version`r`nHost: $hostHeader`r`nUser-Agent: ServerTester/$ToolVersion`r`nAccept: */*`r`nConnection: close`r`n`r`n"

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
                $r.Ok = ($r.Status -ge 200 -and $r.Status -lt 400)
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

    function Measure-Https {
        param([string]$Name, [int]$Port, [int]$TimeoutMs, [string]$Method, [string]$Version, [bool]$ValidateTls, [string]$ToolVersion)

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
                $r.TlsValid = [bool]$ValidateTls
            } catch {
                $swTls.Stop()
                $r.Error = "tls: $($_.Exception.Message)"
                if ($ValidateTls) { $r.TlsValid = $false }
                return $r
            }

            $hostHeader = $Name
            $req = "$Method / HTTP/$Version`r`nHost: $hostHeader`r`nUser-Agent: ServerTester/$ToolVersion`r`nAccept: */*`r`nConnection: close`r`n`r`n"

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
                $r.Ok = ($r.Status -ge 200 -and $r.Status -lt 400)
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

    function Measure-Stratum {
        param([string]$Name, [int]$Port, [int]$TimeoutMs, [int]$MaxBuf, [string]$ToolVersion)

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

            $req = '{"id":1,"method":"mining.subscribe","params":["ServerTester/' + $ToolVersion + '"]}' + "`n"
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
                        } catch {
                            # Not a complete JSON object yet; keep reading.
                        }
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

    $dns = Resolve-IP $HostName

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
            $r = Measure-Stratum -Name $HostName -Port $p -TimeoutMs $AppTimeoutMs -MaxBuf $MaxBufferBytes -ToolVersion $ToolVersion
            $entry.TcpTime      = $r.TcpTime
            $entry.ProtocolTime = $r.AppTime
            $entry.ProtocolOk   = $r.Ok
            $entry.Error        = $r.Error

        } elseif (Test-InList -Value $p -List $HttpsPorts) {
            $entry.Protocol = "https"
            $r = Measure-Https -Name $HostName -Port $p -TimeoutMs $AppTimeoutMs -Method $HttpMethod -Version $HttpVersion -ValidateTls $ValidateTls -ToolVersion $ToolVersion
            $entry.TcpTime      = $r.TcpTime
            $entry.ProtocolTime = $r.AppTime
            $entry.ProtocolOk   = $r.Ok
            $entry.Status       = $r.Status
            $entry.Error        = $r.Error
            $entry.TlsValid     = $r.TlsValid

        } elseif (Test-InList -Value $p -List $HttpPorts) {
            $entry.Protocol = "http"
            $r = Measure-Http -Name $HostName -Port $p -TimeoutMs $AppTimeoutMs -Method $HttpMethod -Version $HttpVersion -ToolVersion $ToolVersion
            $entry.TcpTime      = $r.TcpTime
            $entry.ProtocolTime = $r.AppTime
            $entry.ProtocolOk   = $r.Ok
            $entry.Status       = $r.Status
            $entry.Error        = $r.Error

        } else {
            $entry.Protocol = "tcp"
            $entry.TcpTime  = Measure-TcpConnect -Name $HostName -Port $p -TimeoutMs $TcpTimeoutMs
        }

        $portResults[$p] = $entry
    }

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

    $bestPort = ""
    $bestProtocol = ""
    $bestTime = [double]::MaxValue
    foreach ($p in $Ports) {
        $e = $portResults[$p]
        if ($e.ProtocolOk -and $null -ne $e.ProtocolTime) {
            if ([double]$e.ProtocolTime -lt $bestTime) {
                $bestTime = [double]$e.ProtocolTime
                $bestPort = "$p"
                $bestProtocol = $e.Protocol
            }
        }
    }

    $portResultsList = @($portResults.Values | Sort-Object Port)

    return [PSCustomObject]@{
        Host              = $HostName
        Category          = $CategoryName
        IP                = $dns.Primary
        IPv4              = $dns.IPv4
        IPv6              = $dns.IPv6

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

        TcpOpenPorts      = ($tcpOpenList -join ",")

        StratumPorts      = ($stratumOkList -join ",")
        HttpPorts         = ($httpOkList    -join ",")
        HttpsPorts        = ($httpsOkList   -join ",")

        BestPort          = $bestPort
        BestProtocol      = $bestProtocol
        PortResults       = $portResultsList

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
