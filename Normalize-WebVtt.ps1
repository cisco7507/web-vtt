[CmdletBinding()]
param(
    [string]$VttPath,
    [string]$DurationSeconds,
    [string]$CueIntervalSeconds
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
$script:MaximumSupportedSeconds = [int64]315360000
$script:MaximumGeneratedCues = [int64]1000000

function ConvertTo-PositiveInvariantNumber {
    param(
        [string]$Value,
        [string]$ParameterName
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$ParameterName must not be empty"
    }

    $parsedValue = 0.0
    $parsed = [System.Double]::TryParse(
        $Value,
        [System.Globalization.NumberStyles]::Float,
        $script:InvariantCulture,
        [ref]$parsedValue
    )
    if (-not $parsed) {
        throw "$ParameterName must be a valid invariant-culture number using a period as the decimal separator"
    }
    if ([System.Double]::IsNaN($parsedValue) -or [System.Double]::IsInfinity($parsedValue)) {
        throw "$ParameterName must be a finite number"
    }
    if ($parsedValue -le 0.0) {
        throw "$ParameterName must be greater than zero"
    }

    return $parsedValue
}

function Get-RoundedPositiveSeconds {
    param(
        [double]$Value,
        [string]$ParameterName
    )

    $rounded = [Math]::Ceiling($Value)
    if ($rounded -le 0.0) {
        throw "$ParameterName must be greater than zero after rounding"
    }
    if ($rounded -gt [double]$script:MaximumSupportedSeconds) {
        throw "$ParameterName exceeds the supported maximum of $($script:MaximumSupportedSeconds) seconds"
    }

    return [int64]$rounded
}

function Test-WebVttHeader {
    param([string]$Content)

    $lineEnd = $Content.IndexOfAny([char[]]@("`r", "`n"))
    if ($lineEnd -ge 0) {
        $firstLine = $Content.Substring(0, $lineEnd)
    }
    else {
        $firstLine = $Content
    }

    return ($firstLine -eq 'WEBVTT' -or
        $firstLine.StartsWith('WEBVTT ') -or
        $firstLine.StartsWith("WEBVTT`t"))
}

function Test-WebVttTimingLine {
    param([string]$Line)

    $shortTimestamp = '[0-5][0-9]:[0-5][0-9]\.[0-9]{3}'
    $longTimestamp = '[0-9]{2,}:[0-5][0-9]:[0-5][0-9]\.[0-9]{3}'
    $timestamp = "(?:$longTimestamp|$shortTimestamp)"
    $pattern = "^$timestamp[ `t`f]+-->[ `t`f]+$timestamp(?:[ `t`f]+.*)?$"
    return [System.Text.RegularExpressions.Regex]::IsMatch(
        $Line,
        $pattern,
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
}

function Test-WebVttHasTimedCue {
    param([string]$Content)

    $normalized = $Content.Replace("`r`n", "`n").Replace("`r", "`n")
    $firstNewline = $normalized.IndexOf("`n")
    if ($firstNewline -lt 0 -or $firstNewline -eq ($normalized.Length - 1)) {
        return $false
    }

    $body = $normalized.Substring($firstNewline + 1)
    $blocks = [System.Text.RegularExpressions.Regex]::Split($body, "`n[ `t]*`n+")
    foreach ($block in $blocks) {
        $trimmedBlock = $block.Trim("`n")
        if ($trimmedBlock.Length -eq 0) {
            continue
        }

        $lines = $trimmedBlock.Split([char]"`n")
        $firstLine = $lines[0]
        if ($firstLine -eq 'NOTE' -or $firstLine.StartsWith('NOTE ') -or $firstLine.StartsWith("NOTE`t") -or
            $firstLine -eq 'STYLE' -or $firstLine -eq 'REGION') {
            continue
        }

        if (Test-WebVttTimingLine $firstLine) {
            return $true
        }
        if ($lines.Length -ge 2 -and (Test-WebVttTimingLine $lines[1])) {
            return $true
        }
    }

    return $false
}

function Format-WebVttTimestamp {
    param([int64]$TotalSeconds)

    $hours = [Math]::Floor($TotalSeconds / 3600.0)
    $remaining = $TotalSeconds % 3600L
    $minutes = [int64][Math]::Floor($remaining / 60.0)
    $seconds = $remaining % 60L
    return '{0}:{1:00}:{2:00}.000' -f @(
        ([int64]$hours).ToString('00', $script:InvariantCulture),
        $minutes,
        $seconds
    )
}

function New-GeneratedWebVtt {
    param(
        [int64]$Duration,
        [int64]$Interval
    )

    $cueCount = [int64][Math]::Ceiling($Duration / [double]$Interval)
    if ($cueCount -gt $script:MaximumGeneratedCues) {
        throw "Requested timeline would generate $cueCount cues; the supported maximum is $($script:MaximumGeneratedCues)"
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append("WEBVTT`n`n")
    $start = 0L
    $identifier = 1L
    while ($start -lt $Duration) {
        $remaining = $Duration - $start
        if ($remaining -lt $Interval) {
            $end = $Duration
        }
        else {
            $end = $start + $Interval
        }

        [void]$builder.Append($identifier.ToString($script:InvariantCulture)).Append("`n")
        [void]$builder.Append((Format-WebVttTimestamp $start)).Append(' --> ').Append((Format-WebVttTimestamp $end)).Append("`n")
        [void]$builder.Append([char]0x2060).Append("`n")
        if ($end -lt $Duration) {
            [void]$builder.Append("`n")
        }

        $start = $end
        $identifier++
    }

    return $builder.ToString()
}

function Write-WebVttAtomically {
    param(
        [string]$TargetPath,
        [string]$Content
    )

    $directory = [System.IO.Path]::GetDirectoryName($TargetPath)
    $fileName = [System.IO.Path]::GetFileName($TargetPath)
    $temporaryPath = [System.IO.Path]::Combine(
        $directory,
        ".$fileName.$([Guid]::NewGuid().ToString('N')).tmp"
    )
    $stream = $null
    $writer = $null
    try {
        $stream = New-Object System.IO.FileStream(
            $temporaryPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $writer = New-Object System.IO.StreamWriter(
            $stream,
            (New-Object System.Text.UTF8Encoding($false))
        )
        $writer.NewLine = "`n"
        $writer.Write($Content)
        $writer.Flush()
        $stream.Flush($true)
        $writer.Dispose()
        $writer = $null
        $stream = $null

        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            [System.IO.File]::Replace($temporaryPath, $TargetPath, $null)
        }
        else {
            # This overload is used only on PowerShell 7/.NET on Unix. It maps to a
            # same-filesystem overwrite rename when both paths share a directory.
            [System.IO.File]::Move($temporaryPath, $TargetPath, $true)
        }
    }
    finally {
        if ($null -ne $writer) {
            $writer.Dispose()
        }
        elseif ($null -ne $stream) {
            $stream.Dispose()
        }
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}

function Write-ResultAndExit {
    param(
        [int]$ExitCode,
        [string]$Message
    )

    $singleLineMessage = $Message -replace '[\r\n]+', ' '
    [Console]::Out.WriteLine("RESULT=$singleLineMessage")
    exit $ExitCode
}

try {
    if ([string]::IsNullOrWhiteSpace($VttPath)) {
        throw 'VttPath must not be empty'
    }
    if ([System.IO.Directory]::Exists($VttPath)) {
        throw "VTT path is not a regular file: $VttPath"
    }
    if (-not [System.IO.File]::Exists($VttPath)) {
        throw "VTT file does not exist: $VttPath"
    }

    $fullPath = [System.IO.Path]::GetFullPath($VttPath)
    $attributes = [System.IO.File]::GetAttributes($fullPath)
    if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
        throw "VTT path is not a regular file: $VttPath"
    }

    $durationValue = ConvertTo-PositiveInvariantNumber $DurationSeconds 'DurationSeconds'
    $intervalValue = ConvertTo-PositiveInvariantNumber $CueIntervalSeconds 'CueIntervalSeconds'
    $roundedDuration = Get-RoundedPositiveSeconds $durationValue 'DurationSeconds'
    $roundedInterval = Get-RoundedPositiveSeconds $intervalValue 'CueIntervalSeconds'

    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $content = [System.IO.File]::ReadAllText($fullPath, $strictUtf8)
    if (-not (Test-WebVttHeader $content)) {
        throw 'Invalid WEBVTT header'
    }

    if (-not (Test-WebVttHasTimedCue $content)) {
        $generatedContent = New-GeneratedWebVtt $roundedDuration $roundedInterval
        Write-WebVttAtomically $fullPath $generatedContent
    }

    Write-ResultAndExit 0 '0'
}
catch {
    $message = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = 'Unexpected error'
    }
    Write-ResultAndExit 1 $message
}
