# ========================================================
# Server Tester - State
# ========================================================
# Shared state: version, constants, theme, cleanup.
# Part of ServerTester.ps1. Dot-sourced by the entry script;
# do not run directly.

# ========================================================
# GLOBAL STATE
# ========================================================
$script:VERSION            = "2.2.0"
$script:MAX_PACKETS        = 500
$script:DEFAULT_PACKETS    = 20
$script:MIN_PACKETS        = 1

# Timeouts (ms) - from CLI parameters, see ServerTester.ps1
$script:PING_TIMEOUT_MS    = $PingTimeoutMs
$script:TCP_TIMEOUT_MS     = $TcpTimeoutMs
$script:APP_TIMEOUT_MS     = $AppTimeoutMs
$script:MAX_BUFFER_BYTES   = 65536

# Concurrency - from CLI parameter -MaxWorkers
$script:MAX_WORKERS        = $MaxWorkers

# TLS validation, on by default
$script:VALIDATE_TLS       = [bool]$ValidateTls

# HTTP method and version - from CLI parameters
$script:HTTP_METHOD        = $HttpMethod
$script:HTTP_VERSION       = $HttpVersion

# Menu's chosen packet count. Named MenuPackets (not PACKETS): PowerShell
# variable names are case-insensitive, so $script:PACKETS was the same
# variable as the -Packets CLI parameter and reset it to 20 on load.
$script:MenuPackets         = $script:DEFAULT_PACKETS

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
        # Best-effort cleanup on exit; a failing Close/Dispose must not
        # raise a second error while the engine is shutting down.
        try {
            if ($script:ActivePool) {
                try { $script:ActivePool.Close()   } catch {}
                try { $script:ActivePool.Dispose() } catch {}
            }
            [GC]::Collect()
        } catch {}
    }
}
