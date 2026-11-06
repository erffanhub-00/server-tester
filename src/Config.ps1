# ========================================================
# Server Tester - Config
# ========================================================
# categories.json loading and strict validation.
# Part of ServerTester.ps1. Dot-sourced by the entry script;
# do not run directly.

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

    foreach ($s in @($Cat.servers)) {
        if ($s -isnot [string] -or [string]::IsNullOrWhiteSpace($s) -or $s -notmatch '^[A-Za-z0-9._\-:\[\]]+$') {
            Write-Host "  [!] $Key : invalid server name '$s'" -ForegroundColor $script:Theme.Danger
            return $false
        }
    }

    $ports        = ConvertTo-PortArray $Cat.ports         "ports"         $Key
    $httpPorts    = ConvertTo-PortArray $Cat.http_ports    "http_ports"    $Key
    $httpsPorts   = ConvertTo-PortArray $Cat.https_ports   "https_ports"   $Key
    $stratumPorts = ConvertTo-PortArray $Cat.stratum_ports "stratum_ports" $Key

    if ($null -eq $ports) {
        return $false
    }

    if ($null -eq $httpPorts -or $null -eq $httpsPorts -or $null -eq $stratumPorts) {
        Write-Host "  [!] $Key : invalid protocol ports" -ForegroundColor $script:Theme.Danger
        return $false
    }

    foreach ($p in $httpPorts)    { if ($ports -notcontains $p) { Write-Host "  [!] $Key : http_ports $p not in ports"    -ForegroundColor $script:Theme.Danger; return $false } }
    foreach ($p in $httpsPorts)   { if ($ports -notcontains $p) { Write-Host "  [!] $Key : https_ports $p not in ports"   -ForegroundColor $script:Theme.Danger; return $false } }
    foreach ($p in $stratumPorts) { if ($ports -notcontains $p) { Write-Host "  [!] $Key : stratum_ports $p not in ports" -ForegroundColor $script:Theme.Danger; return $false } }

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
# SERVER DEDUP
# ========================================================
function Get-UniqueServers {
    param([array]$Servers)
    # Duplicate servers in a category waste a worker slot and, worse,
    # results are matched back by host name, so a duplicate entry can show
    # the same result twice while another result is dropped. Keep the first
    # occurrence (case-insensitive) and report the rest.
    $seen = @{}
    $unique = @()
    $duplicates = @()
    foreach ($s in @($Servers)) {
        $key = "$s".ToLowerInvariant()
        if ($seen.ContainsKey($key)) { $duplicates += $s; continue }
        $seen[$key] = $true
        $unique += $s
    }
    return [PSCustomObject]@{
        Servers    = $unique
        Duplicates = $duplicates
    }
}
