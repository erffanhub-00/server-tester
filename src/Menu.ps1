# ========================================================
# Server Tester - Menu
# ========================================================
# Interactive menu, category picker, test orchestration.
# Part of ServerTester.ps1. Dot-sourced by the entry script;
# do not run directly.

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
            $script:MenuPackets = $script:DEFAULT_PACKETS
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
        $script:MenuPackets = $n
        return
    }
}

# ========================================================
# CATEGORY TEST
# ========================================================
function Start-CategoryTest {
    param(
        [string]$CategoryKey,
        $CategoryData,
        [int]$Packets,
        [switch]$Interactive
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

    $dedup = Get-UniqueServers $servers
    if ($dedup.Duplicates.Count -gt 0) {
        Write-Host "  [!] Duplicate server(s) skipped: $($dedup.Duplicates -join ', ')" -ForegroundColor $script:Theme.Warning
    }
    $servers = @($dedup.Servers)

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
        if ($Interactive) { Read-Host "  Press Enter to continue" | Out-Null }
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
                AddParameter("HttpVersion",    $script:HTTP_VERSION).
                AddParameter("ToolVersion",    $script:VERSION)

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
        Show-ServerDetail -r $r -Ports $ports
    }

    Show-Ranking -Results $ordered -CategoryKey $CategoryKey

    Write-Host ""
    if ($Interactive) { Read-Host "  Press Enter to continue" | Out-Null }
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
                        Start-CategoryTest -CategoryKey $k -CategoryData $categories.$k -Packets $script:MenuPackets -Interactive
                    }
                } else {
                    foreach ($k in $sel) {
                        Start-CategoryTest -CategoryKey $k -CategoryData $categories.$k -Packets $script:MenuPackets -Interactive
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
