BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot 'ServerTester.ps1'
    . $scriptPath

    # Get-Percentile lives inside the worker scriptblock, so pull it out for testing.
    $workerPath = Join-Path $PSScriptRoot 'src' 'Worker.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($workerPath, [ref]$null, [ref]$null)
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-Percentile' }, $true) |
        Select-Object -First 1
    if ($fn) { . ([scriptblock]::Create($fn.Extent.Text)) }

    function New-TestRow {
        param(
            [double]$Loss = 0,
            $Avg = 20,
            $Jitter = 2,
            $P95 = 30,
            $Max = 40,
            [string]$StratumPorts = '',
            [string]$HttpsPorts = '',
            [string]$HttpPorts = '',
            [string]$BestPort = '',
            [string]$BestProtocol = '',
            $PortResults = $null
        )
        return [pscustomobject]@{
            Host         = 'example.com'
            Loss         = $Loss
            Avg          = $Avg
            Jitter       = $Jitter
            P95          = $P95
            Max          = $Max
            StratumPorts = $StratumPorts
            HttpsPorts   = $HttpsPorts
            HttpPorts    = $HttpPorts
            BestPort     = $BestPort
            BestProtocol = $BestProtocol
            PortResults  = $PortResults
        }
    }

    function New-TestCategory {
        param(
            [string]$Name = 'Test',
            [string[]]$Servers = @('example.com'),
            [int[]]$Ports = @(80, 443),
            $HttpPorts = @(80),
            $HttpsPorts = @(443),
            $StratumPorts = @()
        )
        return [pscustomobject]@{
            name          = $Name
            servers       = $Servers
            ports         = $Ports
            http_ports    = $HttpPorts
            https_ports   = $HttpsPorts
            stratum_ports = $StratumPorts
        }
    }
}

Describe 'Get-Score' {
    It 'scores a perfect Stratum server low' {
        $row = New-TestRow -Loss 0 -Avg 20 -Jitter 2 -P95 30 -StratumPorts '3333'
        Get-Score $row | Should -Be -13.4
    }

    It 'scores a Down server with the 9999 fallback' {
        $row = New-TestRow -Loss 100 -Avg $null -Jitter $null -P95 $null -Max $null
        Get-Score $row | Should -Be 11149
    }

    It 'gives HTTPS a better bonus than HTTP' {
        $https = New-TestRow -Loss 0 -Avg 100 -Jitter 10 -P95 120 -HttpsPorts '443'
        $http = New-TestRow -Loss 0 -Avg 100 -Jitter 10 -P95 120 -HttpPorts '80'
        Get-Score $https | Should -Be 67
        Get-Score $http | Should -Be 77
    }
}

Describe 'Get-Status' {
    It 'returns Down on 100% loss' {
        Get-Status (New-TestRow -Loss 100) | Should -Be 'Down'
    }

    It 'returns OK with no loss and a working protocol' {
        Get-Status (New-TestRow -Loss 0 -HttpsPorts '443') | Should -Be 'OK'
    }

    It 'returns Reachable with no loss and no working protocol' {
        Get-Status (New-TestRow -Loss 0) | Should -Be 'Reachable'
    }

    It 'returns Degraded on partial loss' {
        Get-Status (New-TestRow -Loss 5) | Should -Be 'Degraded'
    }
}

Describe 'Get-Percentile' {
    It 'returns the median for 1..10' {
        Get-Percentile @(1..10) 50 | Should -Be 5
    }

    It 'returns the max for P95 of 1..10' {
        Get-Percentile @(1..10) 95 | Should -Be 10
    }

    It 'returns null for empty input' {
        Get-Percentile @() 50 | Should -BeNullOrEmpty
    }

    It 'returns the single value for a one-item list' {
        Get-Percentile @(42) 50 | Should -Be 42
    }
}

Describe 'ConvertTo-PortArray' {
    It 'converts valid ports' {
        $r = ConvertTo-PortArray @(80, 443) 'ports' 'test'
        $r.Count | Should -Be 2
        $r | Should -Contain 80
        $r | Should -Contain 443
    }

    It 'returns null for a non-numeric value' {
        ConvertTo-PortArray @('abc') 'ports' 'test' | Should -BeNullOrEmpty
    }

    It 'returns null for out-of-range ports' {
        ConvertTo-PortArray @(0) 'ports' 'test' | Should -BeNullOrEmpty
        ConvertTo-PortArray @(70000) 'ports' 'test' | Should -BeNullOrEmpty
    }

    It 'dedupes ports' {
        $r = ConvertTo-PortArray @(80, 80) 'ports' 'test'
        $r.Count | Should -Be 1
    }

    It 'returns an empty array for null input' {
        $r = ConvertTo-PortArray $null 'ports' 'test'
        $r.Count | Should -Be 0
    }
}

Describe 'Test-CategoryData' {
    It 'accepts a valid category' {
        Test-CategoryData (New-TestCategory) 'test' | Should -Be $true
    }

    It 'rejects a non-numeric http port' {
        $cat = New-TestCategory -HttpPorts @('bad')
        Test-CategoryData $cat 'test' | Should -Be $false
    }

    It 'rejects an out-of-range https port' {
        $cat = New-TestCategory -HttpsPorts @(99999)
        Test-CategoryData $cat 'test' | Should -Be $false
    }

    It 'rejects a protocol port missing from ports' {
        $cat = New-TestCategory -Ports @(443) -HttpPorts @(80) -HttpsPorts @(443)
        Test-CategoryData $cat 'test' | Should -Be $false
    }

    It 'rejects a port in two protocols' {
        $cat = New-TestCategory -HttpPorts @(443) -HttpsPorts @(443)
        Test-CategoryData $cat 'test' | Should -Be $false
    }

    It 'accepts empty protocol port lists' {
        $cat = New-TestCategory -HttpPorts @() -HttpsPorts @() -StratumPorts @()
        Test-CategoryData $cat 'test' | Should -Be $true
    }

    It 'rejects a server name with a space' {
        $cat = New-TestCategory -Servers @('bad host')
        Test-CategoryData $cat 'test' | Should -Be $false
    }

    It 'rejects a server name with a line break' {
        $cat = New-TestCategory -Servers @("a`r`nb")
        Test-CategoryData $cat 'test' | Should -Be $false
    }

    It 'rejects a missing name' {
        $cat = New-TestCategory -Name ''
        Test-CategoryData $cat 'test' | Should -Be $false
    }
}

Describe 'Get-BestProtocol' {
    It 'returns the protocol of the best port, not the fixed priority' {
        $results = @(
            [pscustomobject]@{ Port = 3333; Protocol = 'stratum'; ProtocolOk = $true; ProtocolTime = 500 }
            [pscustomobject]@{ Port = 443; Protocol = 'https'; ProtocolOk = $true; ProtocolTime = 50 }
        )
        $row = New-TestRow -StratumPorts '3333' -HttpsPorts '443' -BestPort '443' -PortResults $results
        Get-BestProtocol $row | Should -Be 'HTTPS'
    }

    It 'returns Stratum when the best port is a Stratum port' {
        $results = @(
            [pscustomobject]@{ Port = 3333; Protocol = 'stratum'; ProtocolOk = $true; ProtocolTime = 50 }
        )
        $row = New-TestRow -BestPort '3333' -PortResults $results
        Get-BestProtocol $row | Should -Be 'Stratum'
    }

    It 'returns empty when there is no best port' {
        $row = New-TestRow -BestPort ''
        Get-BestProtocol $row | Should -Be ''
    }
}

Describe 'Get-BestPortEntry' {
    It 'returns the entry for the best port' {
        $results = @(
            [pscustomobject]@{ Port = 80; Protocol = 'http'; ProtocolOk = $true; ProtocolTime = 10 }
            [pscustomobject]@{ Port = 443; Protocol = 'https'; ProtocolOk = $true; ProtocolTime = 20 }
        )
        $row = New-TestRow -BestPort '443' -PortResults $results
        (Get-BestPortEntry $row).Port | Should -Be 443
    }

    It 'returns null when the best port has no entry' {
        $row = New-TestRow -BestPort '9999' -PortResults @()
        Get-BestPortEntry $row | Should -BeNullOrEmpty
    }
}

Describe 'Get-UniqueServers' {
    It 'keeps the first occurrence and reports the rest' {
        $r = Get-UniqueServers @('a.com', 'b.com', 'a.com')
        $r.Servers.Count | Should -Be 2
        $r.Servers | Should -Be @('a.com', 'b.com')
        $r.Duplicates | Should -Be @('a.com')
    }

    It 'treats host names case-insensitively' {
        $r = Get-UniqueServers @('Example.COM', 'example.com')
        $r.Servers.Count | Should -Be 1
        $r.Duplicates.Count | Should -Be 1
    }

    It 'preserves order' {
        $r = Get-UniqueServers @('c.com', 'a.com', 'b.com', 'a.com')
        $r.Servers | Should -Be @('c.com', 'a.com', 'b.com')
    }

    It 'returns no duplicates for a clean list' {
        $r = Get-UniqueServers @('a.com', 'b.com')
        $r.Duplicates.Count | Should -Be 0
    }

    It 'handles an empty list' {
        $r = Get-UniqueServers @()
        $r.Servers.Count | Should -Be 0
        $r.Duplicates.Count | Should -Be 0
    }
}

Describe 'Get-Score fallbacks' {
    It 'uses the proto-only fallbacks when ICMP fails but HTTPS works' {
        $row = New-TestRow -Loss 100 -Avg $null -Jitter $null -P95 $null -Max $null -HttpsPorts '443'
        Get-Score $row | Should -Be 1370
    }
}

Describe 'Format-Ms and Format-Pct' {
    It 'formats a latency value' {
        Format-Ms 12.345 | Should -Be '12.3 ms'
    }

    It 'returns N/A for null latency' {
        Format-Ms $null | Should -Be 'N/A'
    }

    It 'formats a percentage' {
        Format-Pct 12.34 | Should -Be '12.3%'
    }

    It 'returns N/A for null percentage' {
        Format-Pct $null | Should -Be 'N/A'
    }
}

Describe 'Get-StatusColor' {
    It 'maps each status to a color' {
        Get-StatusColor 'OK' | Should -Be 'Green'
        Get-StatusColor 'Reachable' | Should -Be 'Cyan'
        Get-StatusColor 'Degraded' | Should -Be 'Yellow'
        Get-StatusColor 'Down' | Should -Be 'Red'
    }
}

Describe 'CLI parameters' {
    It 'exposes the tuning knobs with safe defaults' {
        $entryPath = Join-Path $PSScriptRoot 'ServerTester.ps1'
        $entryAst = [System.Management.Automation.Language.Parser]::ParseFile($entryPath, [ref]$null, [ref]$null)
        $byName = @{}
        foreach ($param in $entryAst.ParamBlock.Parameters) {
            $byName[$param.Name.VariablePath.UserPath] = $param
        }

        $byName['MaxWorkers'].DefaultValue.Value | Should -Be 20
        $byName['PingTimeoutMs'].DefaultValue.Value | Should -Be 2000
        $byName['TcpTimeoutMs'].DefaultValue.Value | Should -Be 3000
        $byName['AppTimeoutMs'].DefaultValue.Value | Should -Be 5000
        $byName['HttpMethod'].DefaultValue.Value | Should -Be 'HEAD'
        $byName['HttpVersion'].DefaultValue.Value | Should -Be '1.1'
        $byName['ValidateTls'].DefaultValue.Extent.Text | Should -Be '$true'
    }
}

Describe 'Packets parameter collision' {
    It 'does not reset the -Packets parameter to the default' {
        # The old $script:PACKETS variable had the same name
        # (case-insensitive) as the -Packets parameter, so loading the
        # script reset any -Packets value to 20 in -NoMenu mode.
        Get-Variable -Name 'PACKETS' -Scope Script -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
        $script:MenuPackets | Should -Be 20
    }
}
