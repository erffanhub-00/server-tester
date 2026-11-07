# ========================================================
# Server Tester - POWER EDITION
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
    [ValidateRange(1, 500)]
    [int]   $Packets,
    [string]$ConfigFile = "categories.json",
    [string]$OutputDir  = "output",
    [switch]$NoMenu,
    [switch]$ValidateTls = $true,
    [ValidateRange(1, 50)]
    [int]   $MaxWorkers = 20,
    [ValidateRange(100, 60000)]
    [int]   $PingTimeoutMs = 2000,
    [ValidateRange(100, 60000)]
    [int]   $TcpTimeoutMs = 3000,
    [ValidateRange(100, 60000)]
    [int]   $AppTimeoutMs = 5000,
    [ValidateSet('HEAD', 'GET')]
    [string]$HttpMethod = 'HEAD',
    [ValidateSet('1.0', '1.1')]
    [string]$HttpVersion = '1.1'
)


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
    try { New-Item -ItemType Directory -Path $script:OutputPath -Force | Out-Null }
    catch { Write-Warning "Could not create output directory '$script:OutputPath'. Reports will fail to save." }
}

# ========================================================
# MODULES
# ========================================================
# The implementation lives in src/ and is dot-sourced here, so the
# entry script stays small. Dot-sourcing keeps the same script scope,
# so $script: state set in the modules is shared with the entry script.
$script:ModuleFiles = @(
    'State.ps1'
    'UI.ps1'
    'Config.ps1'
    'Scoring.ps1'
    'Worker.ps1'
    'Output.ps1'
    'Menu.ps1'
)
foreach ($module in $script:ModuleFiles) {
    . (Join-Path $PSScriptRoot "src/$module")
}

# ========================================================
# ENTRY POINT
# ========================================================
if ($MyInvocation.InvocationName -ne '.') {
    Register-Cleanup

    if ($NoMenu -xor [bool]$CategoryName) {
        Write-Host "Use -NoMenu together with -CategoryName." -ForegroundColor $script:Theme.Danger
        exit 1
    }

    if ($NoMenu -and $CategoryName) {
        $categories = Load-Categories
        if (-not $categories) { exit 1 }
        if (-not $Packets) { $Packets = $script:DEFAULT_PACKETS }
        if (-not $categories.$CategoryName) {
            Write-Host "Category not found: $CategoryName" -ForegroundColor $script:Theme.Danger
            exit 1
        }
        Start-CategoryTest -CategoryKey $CategoryName -CategoryData $categories.$CategoryName -Packets $Packets
        exit 0
    }

    Main-Menu
}
