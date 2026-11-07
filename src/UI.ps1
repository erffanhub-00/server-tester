# ========================================================
# Server Tester - UI
# ========================================================
# Console output primitives: borders, banner, formatting.
# Part of ServerTester.ps1. Dot-sourced by the entry script;
# do not run directly.

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
