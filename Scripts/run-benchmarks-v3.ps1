param(
    [string[]]$Scenarios = @("compute", "simple", "file-read", "file-write", "json", "auth"),
    [int]$Repetitions = 5,
    [int]$DurationSeconds = 30,
    [int]$WarmupSeconds = 5,
    [int]$CooldownSeconds = 20,
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ProjectRoot

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$ResultsRoot = Join-Path $ProjectRoot "results\$Timestamp"
$RawDir = Join-Path $ResultsRoot "autocannon"
$StatsDir = Join-Path $ResultsRoot "docker-stats"
$WriteTempDir = Join-Path $ProjectRoot "data\temp"
$JsonInputFile = Join-Path $ProjectRoot "json-1mb.json"
$AuthInputFile = Join-Path $ResultsRoot "auth-body.json"

New-Item -ItemType Directory -Force -Path $RawDir | Out-Null
New-Item -ItemType Directory -Force -Path $StatsDir | Out-Null
New-Item -ItemType Directory -Force -Path $WriteTempDir | Out-Null

[System.IO.File]::WriteAllText(
    $AuthInputFile,
    '{"password":"diploma-benchmark-test-password"}',
    [System.Text.UTF8Encoding]::new($false)
)

$NpxCommand = (Get-Command npx.cmd -ErrorAction SilentlyContinue)
if (-not $NpxCommand) {
    $NpxCommand = Get-Command npx -ErrorAction Stop
}
$NpxPath = $NpxCommand.Source

$DockerCommand = Get-Command docker -ErrorAction Stop
$DockerPath = $DockerCommand.Source

$Runtimes = @{
    node = @{
        Service   = "node-server"
        Other     = "bun-server"
        Container = "node_benchmark_container"
        BaseUrl   = "http://localhost:3000"
    }
    bun = @{
        Service   = "bun-server"
        Other     = "node-server"
        Container = "bun_benchmark_container"
        BaseUrl   = "http://localhost:3001"
    }
}

$ScenarioConfig = @{
    "simple" = @{
        Path        = "/simple"
        Method      = "GET"
        Connections = 100
        InputFile   = $null
        JsonHeader  = $false
    }
    "compute" = @{
        Path        = "/compute"
        Method      = "GET"
        Connections = 10
        InputFile   = $null
        JsonHeader  = $false
    }
    "file-read" = @{
        Path        = "/file-read"
        Method      = "GET"
        Connections = 20
        InputFile   = $null
        JsonHeader  = $false
    }
    "file-write" = @{
        Path        = "/file-write"
        Method      = "POST"
        Connections = 20
        InputFile   = $null
        JsonHeader  = $false
    }
    "json" = @{
        Path        = "/json"
        Method      = "POST"
        Connections = 20
        InputFile   = $JsonInputFile
        JsonHeader  = $true
    }
    "auth" = @{
        Path        = "/auth"
        Method      = "POST"
        Connections = 10
        InputFile   = $AuthInputFile
        JsonHeader  = $true
    }
}

function Assert-Prerequisites {
    if (-not (Test-Path (Join-Path $ProjectRoot "docker-compose.yml"))) {
        throw "docker-compose.yml ni v isti mapi kot skripta."
    }

    foreach ($scenario in $Scenarios) {
        if (-not $ScenarioConfig.ContainsKey($scenario)) {
            throw "Neznan scenarij: $scenario"
        }
    }

    if ($Scenarios -contains "json" -and -not (Test-Path $JsonInputFile)) {
        throw "Manjka datoteka json-1mb.json: $JsonInputFile"
    }

    if (Test-Path $JsonInputFile) {
        $jsonSize = (Get-Item $JsonInputFile).Length
        Write-Host "json-1mb.json: $jsonSize B"
    }

    $readFile = Join-Path $ProjectRoot "data\test-10mb.txt"
    if (Test-Path $readFile) {
        $readSize = (Get-Item $readFile).Length
        Write-Host "test-10mb.txt: $readSize B"
        if ($readSize -ne 10485760) {
            Write-Warning "test-10mb.txt ni tocno 10 MiB (10485760 B). V diplomi navedi dejansko velikost."
        }
    }
    elseif ($Scenarios -contains "file-read") {
        throw "Manjka data\test-10mb.txt."
    }
}

function Clear-WriteTemp {
    if (-not (Test-Path $WriteTempDir)) {
        New-Item -ItemType Directory -Force -Path $WriteTempDir | Out-Null
        return
    }

    Get-ChildItem -Path $WriteTempDir -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction Stop
}

function Wait-ServerReady {
    param(
        [string]$BaseUrl,
        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest `
                -Uri "$BaseUrl/simple" `
                -Method GET `
                -TimeoutSec 2 `
                -UseBasicParsing

            if ($response.StatusCode -eq 200) {
                return
            }
        }
        catch {
            Start-Sleep -Milliseconds 500
        }
    }

    throw "Streznik $BaseUrl ni postal pripravljen v $TimeoutSeconds sekundah."
}

function Start-CleanRuntime {
    param([string]$Runtime)

    $cfg = $Runtimes[$Runtime]

    & $DockerPath compose stop $cfg.Other | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Ni bilo mogoce ustaviti drugega runtime-a: $($cfg.Other)"
    }

    & $DockerPath compose up -d $cfg.Service | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Ni bilo mogoce zagnati runtime-a: $Runtime"
    }

    & $DockerPath compose restart $cfg.Service | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Ni bilo mogoce restartati runtime-a: $Runtime"
    }

    Wait-ServerReady -BaseUrl $cfg.BaseUrl
}

function Get-AutocannonArgs {
    param(
        [string]$Scenario,
        [string]$Runtime,
        [int]$Seconds,
        [bool]$JsonOutput
    )

    $s = $ScenarioConfig[$Scenario]
    $cfg = $Runtimes[$Runtime]
    $url = "$($cfg.BaseUrl)$($s.Path)"

    $acArgs = @(
        "autocannon",
        "-c", [string]$s.Connections,
        "-d", [string]$Seconds,
        "-n"
    )

    if ($s.Method -ne "GET") {
        $acArgs += @("-m", $s.Method)
    }

    if ($s.JsonHeader) {
        $acArgs += @("-H", "Content-Type=application/json")
    }

    if ($s.InputFile) {
        $acArgs += @("-i", $s.InputFile)
    }

    if ($JsonOutput) {
        $acArgs += "-j"
    }

    $acArgs += $url
    return ,$acArgs
}


function Quote-CmdArgument {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    return '"' + ($Value -replace '"', '\"') + '"'
}

function Start-NpxAutocannonProcess {
    param([string[]]$AutocannonArgs)

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add((Quote-CmdArgument $NpxPath))

    foreach ($argument in $AutocannonArgs) {
        $parts.Add((Quote-CmdArgument ([string]$argument)))
    }

    $innerCommand = $parts -join ' '

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.Arguments = "/d /s /c `"$innerCommand`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    if (-not $process.Start()) {
        throw "Ni bilo mogoce zagnati Autocannona."
    }

    return $process
}

function Invoke-Warmup {
    param(
        [string]$Scenario,
        [string]$Runtime
    )

    if ($WarmupSeconds -le 0) {
        return
    }

    $acArgs = Get-AutocannonArgs `
        -Scenario $Scenario `
        -Runtime $Runtime `
        -Seconds $WarmupSeconds `
        -JsonOutput $false

    $warmupOut = Join-Path $ResultsRoot "warmup-$Scenario-$Runtime.out.txt"
    $warmupErr = Join-Path $ResultsRoot "warmup-$Scenario-$Runtime.err.txt"

    $warmupProcess = Start-NpxAutocannonProcess -AutocannonArgs $acArgs
    $warmupProcess.WaitForExit()

    $warmupStdout = $warmupProcess.StandardOutput.ReadToEnd()
    $warmupStderr = $warmupProcess.StandardError.ReadToEnd()

    [System.IO.File]::WriteAllText(
        $warmupOut,
        $warmupStdout,
        [System.Text.UTF8Encoding]::new($false)
    )
    [System.IO.File]::WriteAllText(
        $warmupErr,
        $warmupStderr,
        [System.Text.UTF8Encoding]::new($false)
    )

    if ($warmupProcess.ExitCode -ne 0) {
        throw "Warm-up ni uspel: $Runtime / $Scenario. Poglej $warmupErr"
    }

    Remove-Item $warmupOut, $warmupErr -Force -ErrorAction SilentlyContinue
}

function Convert-MemoryToMiB {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $text = $Value.Trim()

    if ($text -match '^([\d\.,]+)\s*([KMGTP]?i?B)$') {
        $numberText = $matches[1].Replace(",", ".")
        $number = [double]::Parse(
            $numberText,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
        $unit = $matches[2]

        switch ($unit) {
            "B"   { return $number / 1MB }
            "KiB" { return $number / 1024 }
            "kB"  { return $number / 1024 }
            "MiB" { return $number }
            "MB"  { return $number * 1000000 / 1048576 }
            "GiB" { return $number * 1024 }
            "GB"  { return $number * 1000000000 / 1048576 }
            "TiB" { return $number * 1024 * 1024 }
            "TB"  { return $number * 1000000000000 / 1048576 }
        }
    }

    return $null
}

function Get-PropertyValue {
    param(
        $Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Read-AutocannonJson {
    param([string]$Path)

    $lines = Get-Content -Path $Path -ErrorAction Stop |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    if (-not $lines) {
        throw "Autocannon ni ustvaril JSON rezultata: $Path"
    }

    $lastJsonLine = $lines |
        Where-Object { $_.TrimStart().StartsWith("{") } |
        Select-Object -Last 1

    if (-not $lastJsonLine) {
        throw "V datoteki ni veljavne JSON vrstice: $Path"
    }

    return $lastJsonLine | ConvertFrom-Json
}

function Invoke-MeasuredRun {
    param(
        [string]$Scenario,
        [string]$Runtime,
        [int]$Repetition
    )

    $cfg = $Runtimes[$Runtime]
    $s = $ScenarioConfig[$Scenario]

    $baseName = "{0}_{1}_run{2}" -f $Scenario, $Runtime, $Repetition
    $jsonPath = Join-Path $RawDir "$baseName.json"
    $stderrPath = Join-Path $RawDir "$baseName.stderr.txt"
    $statsPath = Join-Path $StatsDir "$baseName.csv"

    $acArgs = Get-AutocannonArgs `
        -Scenario $Scenario `
        -Runtime $Runtime `
        -Seconds $DurationSeconds `
        -JsonOutput $true

    $process = Start-NpxAutocannonProcess -AutocannonArgs $acArgs

    $samples = New-Object System.Collections.Generic.List[object]
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $sampleNumber = 0

    while (-not $process.HasExited) {
        $sampleNumber++

        $raw = & $DockerPath stats `
            --no-stream `
            --format "{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}" `
            $cfg.Container

        if ($raw) {
            $parts = $raw -split '\|'

            if ($parts.Count -ge 3) {
                $cpuText = $parts[0].Trim().TrimEnd("%")
                $memoryCurrent = ($parts[1] -split '/')[0].Trim()
                $memPercentText = $parts[2].Trim().TrimEnd("%")

                $cpu = 0.0
                $memPercent = 0.0

                [void][double]::TryParse(
                    $cpuText.Replace(",", "."),
                    [System.Globalization.NumberStyles]::Float,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [ref]$cpu
                )

                [void][double]::TryParse(
                    $memPercentText.Replace(",", "."),
                    [System.Globalization.NumberStyles]::Float,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [ref]$memPercent
                )

                $samples.Add([pscustomobject]@{
                    sample          = $sampleNumber
                    elapsed_seconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
                    timestamp       = (Get-Date).ToString("o")
                    cpu_percent     = $cpu
                    memory_usage    = $memoryCurrent
                    memory_mib      = Convert-MemoryToMiB $memoryCurrent
                    memory_percent  = $memPercent
                })
            }
        }

        Start-Sleep -Seconds 1
        $process.Refresh()
    }

    $process.WaitForExit()
    $stopwatch.Stop()
    $exitCode = $process.ExitCode

    $autocannonStdout = $process.StandardOutput.ReadToEnd()
    $autocannonStderr = $process.StandardError.ReadToEnd()

    [System.IO.File]::WriteAllText(
        $jsonPath,
        $autocannonStdout,
        [System.Text.UTF8Encoding]::new($false)
    )
    [System.IO.File]::WriteAllText(
        $stderrPath,
        $autocannonStderr,
        [System.Text.UTF8Encoding]::new($false)
    )

    $samples | Export-Csv -Path $statsPath -NoTypeInformation -Encoding UTF8

    if ([int]$exitCode -ne 0) {
        throw "Autocannon ni uspel: $Runtime / $Scenario / run $Repetition. Poglej $stderrPath"
    }

    $result = Read-AutocannonJson -Path $jsonPath

    $cpuValues = @($samples | Where-Object {
        $null -ne $_.cpu_percent
    } | ForEach-Object {
        [double]$_.cpu_percent
    })

    $memValues = @($samples | Where-Object {
        $null -ne $_.memory_mib
    } | ForEach-Object {
        [double]$_.memory_mib
    })

    $avgCpu = if ($cpuValues.Count -gt 0) {
        ($cpuValues | Measure-Object -Average).Average
    } else {
        $null
    }

    $avgMem = if ($memValues.Count -gt 0) {
        ($memValues | Measure-Object -Average).Average
    } else {
        $null
    }

    $maxMem = if ($memValues.Count -gt 0) {
        ($memValues | Measure-Object -Maximum).Maximum
    } else {
        $null
    }

    $twoXx = Get-PropertyValue -Object $result -Name "2xx"
    $non2xx = Get-PropertyValue -Object $result -Name "non2xx"
    $errors = Get-PropertyValue -Object $result -Name "errors"
    $timeouts = Get-PropertyValue -Object $result -Name "timeouts"

    return [pscustomobject]@{
        scenario             = $Scenario
        runtime              = $Runtime
        repetition           = $Repetition
        connections          = $s.Connections
        duration_seconds     = $DurationSeconds
        warmup_seconds       = $WarmupSeconds

        latency_avg_ms       = Get-PropertyValue $result.latency "average"
        latency_p50_ms       = Get-PropertyValue $result.latency "p50"
        latency_p97_5_ms     = Get-PropertyValue $result.latency "p97_5"
        latency_p99_ms       = Get-PropertyValue $result.latency "p99"
        latency_stddev_ms    = Get-PropertyValue $result.latency "stddev"
        latency_max_ms       = Get-PropertyValue $result.latency "max"

        requests_avg_sec     = Get-PropertyValue $result.requests "average"
        requests_total       = Get-PropertyValue $result.requests "total"
        throughput_avg_bps   = Get-PropertyValue $result.throughput "average"

        responses_2xx        = $twoXx
        responses_non2xx     = $non2xx
        errors               = $errors
        timeouts             = $timeouts

        cpu_avg_percent      = if ($null -ne $avgCpu) { [math]::Round($avgCpu, 3) } else { $null }
        memory_avg_mib       = if ($null -ne $avgMem) { [math]::Round($avgMem, 3) } else { $null }
        memory_max_mib       = if ($null -ne $maxMem) { [math]::Round($maxMem, 3) } else { $null }
        docker_stats_samples = $samples.Count

        autocannon_file      = $jsonPath
        docker_stats_file    = $statsPath
    }
}

function Get-RuntimeOrder {
    param([int]$Repetition)

    if (($Repetition % 2) -eq 1) {
        return @("node", "bun")
    }

    return @("bun", "node")
}

Assert-Prerequisites

Write-Host ""
Write-Host "Skripta: v3 (robusten zagon npx prek cmd.exe)"
Write-Host "Rezultati: $ResultsRoot"
Write-Host "Scenariji: $($Scenarios -join ', ')"
Write-Host "Ponovitve: $Repetitions"
Write-Host "Meritev: $DurationSeconds s"
Write-Host "Warm-up: $WarmupSeconds s"
Write-Host "Premor: $CooldownSeconds s"
Write-Host ""

if (-not $SkipBuild) {
    Write-Host "Gradim Node in Bun Docker image ..."
    & $DockerPath compose down | Out-Null
    & $DockerPath compose build node-server bun-server

    if ($LASTEXITCODE -ne 0) {
        throw "Docker build ni uspel."
    }

    & $DockerPath compose up -d | Out-Null
}
else {
    Write-Host "Docker build preskocen."
    & $DockerPath compose up -d | Out-Null
}

$allResults = New-Object System.Collections.Generic.List[object]
$orderLog = New-Object System.Collections.Generic.List[object]

foreach ($scenario in $Scenarios) {
    Write-Host ""
    Write-Host "========== $scenario =========="

    for ($rep = 1; $rep -le $Repetitions; $rep++) {
        $order = Get-RuntimeOrder -Repetition $rep

        $orderLog.Add([pscustomobject]@{
            scenario   = $scenario
            repetition = $rep
            first      = $order[0]
            second     = $order[1]
        })

        foreach ($runtime in $order) {
            Write-Host ""
            Write-Host "[$scenario] run $rep/$Repetitions, $runtime"

            Start-CleanRuntime -Runtime $runtime

            if ($scenario -eq "file-write") {
                Clear-WriteTemp
            }

            Write-Host "Warm-up $WarmupSeconds s ..."
            Invoke-Warmup -Scenario $scenario -Runtime $runtime


            if ($scenario -eq "file-write") {
                Clear-WriteTemp
            }

            Start-Sleep -Seconds 2

            Write-Host "Meritev $DurationSeconds s ..."
            $runResult = Invoke-MeasuredRun `
                -Scenario $scenario `
                -Runtime $runtime `
                -Repetition $rep

            $allResults.Add($runResult)

            $allResults |
                Export-Csv `
                    -Path (Join-Path $ResultsRoot "summary-runs.csv") `
                    -NoTypeInformation `
                    -Encoding UTF8

            if ($scenario -eq "file-write") {
                Clear-WriteTemp
            }

            Write-Host (
                "Avg latency: {0} ms, RPS: {1}, 2xx: {2}, non-2xx: {3}, CPU avg: {4}%, RAM avg: {5} MiB" -f
                $runResult.latency_avg_ms,
                $runResult.requests_avg_sec,
                $runResult.responses_2xx,
                $runResult.responses_non2xx,
                $runResult.cpu_avg_percent,
                $runResult.memory_avg_mib
            )

            if ($CooldownSeconds -gt 0) {
                Write-Host "Premor $CooldownSeconds s ..."
                Start-Sleep -Seconds $CooldownSeconds
            }
        }
    }
}

$orderLog |
    Export-Csv `
        -Path (Join-Path $ResultsRoot "run-order.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$aggregate = $allResults |
    Group-Object scenario, runtime |
    ForEach-Object {
        $rows = $_.Group

        function Avg($name) {
            $vals = @($rows |
                ForEach-Object { $_.$name } |
                Where-Object { $null -ne $_ -and $_ -ne "" } |
                ForEach-Object { [double]$_ })

            if ($vals.Count -eq 0) { return $null }
            return [math]::Round(
                ($vals | Measure-Object -Average).Average,
                3
            )
        }

        function StdDev($name) {
            $vals = @($rows |
                ForEach-Object { $_.$name } |
                Where-Object { $null -ne $_ -and $_ -ne "" } |
                ForEach-Object { [double]$_ })

            if ($vals.Count -lt 2) { return $null }

            $mean = ($vals | Measure-Object -Average).Average
            $sumSquares = 0.0

            foreach ($v in $vals) {
                $sumSquares += [math]::Pow($v - $mean, 2)
            }

            return [math]::Round(
                [math]::Sqrt($sumSquares / ($vals.Count - 1)),
                3
            )
        }

        [pscustomobject]@{
            scenario                 = $rows[0].scenario
            runtime                  = $rows[0].runtime
            independent_runs         = $rows.Count

            latency_avg_ms_mean      = Avg "latency_avg_ms"
            latency_avg_ms_sd        = StdDev "latency_avg_ms"

            latency_p50_ms_mean      = Avg "latency_p50_ms"
            latency_p99_ms_mean      = Avg "latency_p99_ms"

            requests_avg_sec_mean    = Avg "requests_avg_sec"
            requests_avg_sec_sd      = StdDev "requests_avg_sec"

            cpu_avg_percent_mean     = Avg "cpu_avg_percent"
            cpu_avg_percent_sd       = StdDev "cpu_avg_percent"

            memory_avg_mib_mean      = Avg "memory_avg_mib"
            memory_avg_mib_sd        = StdDev "memory_avg_mib"

            total_2xx                = [long](($rows.responses_2xx |
                Where-Object { $null -ne $_ -and $_ -ne "" } |
                Measure-Object -Sum).Sum)

            total_non2xx             = [long](($rows.responses_non2xx |
                Where-Object { $null -ne $_ -and $_ -ne "" } |
                Measure-Object -Sum).Sum)

            total_errors             = [long](($rows.errors |
                Where-Object { $null -ne $_ -and $_ -ne "" } |
                Measure-Object -Sum).Sum)

            total_timeouts           = [long](($rows.timeouts |
                Where-Object { $null -ne $_ -and $_ -ne "" } |
                Measure-Object -Sum).Sum)
        }
    }

$aggregate |
    Sort-Object scenario, runtime |
    Export-Csv `
        -Path (Join-Path $ResultsRoot "summary-aggregate.csv") `
        -NoTypeInformation `
        -Encoding UTF8

& $DockerPath compose up -d node-server bun-server | Out-Null

Write-Host ""
Write-Host "KONCANO"
Write-Host "Posamezne ponovitve: $(Join-Path $ResultsRoot 'summary-runs.csv')"
Write-Host "Povprecja in SD:       $(Join-Path $ResultsRoot 'summary-aggregate.csv')"
Write-Host "Vrstni red:            $(Join-Path $ResultsRoot 'run-order.csv')"
Write-Host "Raw Autocannon JSON:   $RawDir"
Write-Host "Docker stats:          $StatsDir"
