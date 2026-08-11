function Test-IsAdministrator {
    [CmdletBinding()]
    param()

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Update-ProcessPath {
    [CmdletBinding()]
    param()

    $parts = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    $sources = @(
        $env:PATH,
        [Environment]::GetEnvironmentVariable('Path', 'Machine'),
        [Environment]::GetEnvironmentVariable('Path', 'User')
    )

    foreach ($source in $sources) {
        if ([string]::IsNullOrWhiteSpace($source)) {
            continue
        }

        foreach ($part in ($source -split ';')) {
            $clean = $part.Trim()
            if ([string]::IsNullOrWhiteSpace($clean)) {
                continue
            }

            if ($seen.Add($clean)) {
                [void]$parts.Add($clean)
            }
        }
    }

    $env:PATH = ($parts -join ';')
    $env:PATH
}

function Join-ProcessArguments {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$Arguments = @()
    )

    $quoted = foreach ($argument in $Arguments) {
        if ($null -eq $argument) {
            '""'
            continue
        }

        $text = [string]$argument
        if ($text.Length -eq 0) {
            '""'
            continue
        }

        if ($text -notmatch '[\s"]') {
            $text
            continue
        }

        $builder = New-Object System.Text.StringBuilder
        [void]$builder.Append('"')
        $backslashes = 0

        foreach ($char in $text.ToCharArray()) {
            if ($char -eq '\') {
                $backslashes++
                continue
            }

            if ($char -eq '"') {
                [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
                [void]$builder.Append('"')
                $backslashes = 0
                continue
            }

            if ($backslashes -gt 0) {
                [void]$builder.Append(('\' * $backslashes))
                $backslashes = 0
            }

            [void]$builder.Append($char)
        }

        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * ($backslashes * 2)))
        }

        [void]$builder.Append('"')
        $builder.ToString()
    }

    $quoted -join ' '
}

function Split-CommandLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$CommandLine
    )

    $tokens = New-Object System.Collections.Generic.List[string]
    $builder = New-Object System.Text.StringBuilder
    $inQuotes = $false

    foreach ($char in $CommandLine.ToCharArray()) {
        if ($char -eq '"') {
            $inQuotes = -not $inQuotes
            continue
        }

        if (-not $inQuotes -and [char]::IsWhiteSpace($char)) {
            if ($builder.Length -gt 0) {
                [void]$tokens.Add($builder.ToString())
                [void]$builder.Clear()
            }
            continue
        }

        [void]$builder.Append($char)
    }

    if ($builder.Length -gt 0) {
        [void]$tokens.Add($builder.ToString())
    }

    @($tokens.ToArray())
}

function Invoke-ExternalCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath,

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$Arguments = @(),

        [Parameter()]
        [ValidateRange(0, 86400)]
        [int]$TimeoutSeconds = 0
    )

    $process = $null
    $startedAt = Get-Date
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()

    try {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $FilePath
        $startInfo.Arguments = Join-ProcessArguments -Arguments $Arguments
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true

        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo

        if (-not $process.Start()) {
            throw 'The process could not be started.'
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = $false

        if ($TimeoutSeconds -gt 0) {
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                $timedOut = $true
                try {
                    $process.Kill()
                }
                catch {
                    # The process may already be finished when the forced stop runs.
                }
            }
        }
        else {
            $process.WaitForExit()
        }

        $process.WaitForExit()
        $stopwatch.Stop()

        [PSCustomObject]@{
            FilePath      = $FilePath
            Arguments     = $Arguments
            ExitCode      = if ($timedOut) { -1 } else { $process.ExitCode }
            StdOut        = $stdoutTask.Result
            StdErr        = $stderrTask.Result
            TimedOut      = $timedOut
            FailedToStart = $false
            StartedAt     = $startedAt
            DurationMs    = $stopwatch.ElapsedMilliseconds
        }
    }
    catch {
        $stopwatch.Stop()

        [PSCustomObject]@{
            FilePath      = $FilePath
            Arguments     = $Arguments
            ExitCode      = 9009
            StdOut        = ''
            StdErr        = $_.Exception.Message
            TimedOut      = $false
            FailedToStart = $true
            StartedAt     = $startedAt
            DurationMs    = $stopwatch.ElapsedMilliseconds
        }
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Restart-AsAdministrator {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ })]
        [string]$ScriptPath
    )

    $currentProcess = Get-Process -Id $PID
    $powerShellPath = $currentProcess.Path

    if ([string]::IsNullOrWhiteSpace($powerShellPath)) {
        if ($PSVersionTable.PSEdition -eq 'Core') {
            $powerShellPath = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
        }
        else {
            $powerShellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        }
    }

    $arguments = Join-ProcessArguments -Arguments @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $ScriptPath
    )

    Start-Process -FilePath $powerShellPath -ArgumentList $arguments -Verb RunAs
}
