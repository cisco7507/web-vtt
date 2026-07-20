[CmdletBinding()]
param(
    [string]$VttPath,
    [string]$DurationSeconds,
    [string]$CueIntervalSeconds
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
$script:MaximumSupportedMilliseconds = [int64]315360000000
$script:MaximumGeneratedCues = [int64]1000000
$script:TimestampPattern = '(?:(?:[0-9]{2,}):[0-5][0-9]:[0-5][0-9]\.[0-9]{3}|[0-5][0-9]:[0-5][0-9]\.[0-9]{3})'

function ConvertTo-InvariantPositiveDouble {
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

function ConvertTo-PositiveMilliseconds {
    param(
        [double]$Value,
        [string]$ParameterName
    )

    $maximumSeconds = $script:MaximumSupportedMilliseconds / 1000.0
    if ($Value -gt $maximumSeconds) {
        throw "$ParameterName exceeds the supported millisecond range"
    }

    $scaledValue = $Value * 1000.0
    if ([System.Double]::IsInfinity($scaledValue) -or $scaledValue -gt [double]$script:MaximumSupportedMilliseconds) {
        throw "$ParameterName exceeds the supported millisecond range"
    }

    $milliseconds = [Math]::Round(
        $scaledValue,
        0,
        [System.MidpointRounding]::AwayFromZero
    )
    if ($milliseconds -le 0.0) {
        throw "$ParameterName rounds to zero milliseconds"
    }
    if ($milliseconds -gt [double]$script:MaximumSupportedMilliseconds) {
        throw "$ParameterName exceeds the supported millisecond range"
    }

    return [int64]$milliseconds
}

function Test-WebVttHeader {
    param([string]$FirstLine)

    return (
        $FirstLine -eq 'WEBVTT' -or
        $FirstLine.StartsWith('WEBVTT ') -or
        $FirstLine.StartsWith("WEBVTT`t")
    )
}

function Get-IntegerQuotient {
    param(
        [int64]$Dividend,
        [int64]$Divisor
    )

    $remainder = 0L
    return [System.Math]::DivRem($Dividend, $Divisor, [ref]$remainder)
}

function ConvertFrom-WebVttTimestamp {
    param(
        [string]$Timestamp,
        [int]$LineNumber
    )

    $match = [System.Text.RegularExpressions.Regex]::Match(
        $Timestamp,
        '^(?:(?<hours>[0-9]{2,}):(?<longMinutes>[0-5][0-9])|(?<shortMinutes>[0-5][0-9])):(?<seconds>[0-5][0-9])\.(?<milliseconds>[0-9]{3})$',
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    if (-not $match.Success) {
        throw "Invalid WebVTT timestamp at line $LineNumber`: $Timestamp"
    }

    if ($match.Groups['hours'].Success) {
        $hoursText = $match.Groups['hours'].Value
        $hours = 0L
        if (-not [System.Int64]::TryParse(
            $hoursText,
            [System.Globalization.NumberStyles]::None,
            $script:InvariantCulture,
            [ref]$hours
        )) {
            throw "WebVTT timestamp exceeds the supported range at line $LineNumber`: $Timestamp"
        }
        $minutes = [int64]$match.Groups['longMinutes'].Value
    }
    else {
        $hours = 0L
        $minutes = [int64]$match.Groups['shortMinutes'].Value
    }

    $seconds = [int64]$match.Groups['seconds'].Value
    $milliseconds = [int64]$match.Groups['milliseconds'].Value
    $nonHourMilliseconds = ($minutes * 60000L) + ($seconds * 1000L) + $milliseconds
    $maximumHours = Get-IntegerQuotient (
        $script:MaximumSupportedMilliseconds - $nonHourMilliseconds
    ) 3600000L
    if ($hours -gt $maximumHours) {
        throw "WebVTT timestamp exceeds the supported range at line $LineNumber`: $Timestamp"
    }

    return ($hours * 3600000L) + $nonHourMilliseconds
}

function Format-WebVttTimestamp {
    param([int64]$TotalMilliseconds)

    if ($TotalMilliseconds -lt 0L -or $TotalMilliseconds -gt $script:MaximumSupportedMilliseconds) {
        throw "Timestamp milliseconds are outside the supported range: $TotalMilliseconds"
    }

    $hours = Get-IntegerQuotient $TotalMilliseconds 3600000L
    $remaining = $TotalMilliseconds % 3600000L
    $minutes = Get-IntegerQuotient $remaining 60000L
    $remaining = $remaining % 60000L
    $seconds = Get-IntegerQuotient $remaining 1000L
    $milliseconds = $remaining % 1000L
    return '{0}:{1:00}:{2:00}.{3:000}' -f @(
        $hours.ToString('00', $script:InvariantCulture),
        $minutes,
        $seconds,
        $milliseconds
    )
}

function Get-SanitizedBlockExcerpt {
    param([string[]]$Lines)

    $excerpt = ($Lines -join ' ') -replace '[\r\n\t]+', ' '
    $excerpt = $excerpt.Trim()
    if ($excerpt.Length -eq 0) {
        return '<whitespace-only>'
    }
    if ($excerpt.Length -gt 80) {
        return $excerpt.Substring(0, 77) + '...'
    }
    return $excerpt
}

function ConvertFrom-WebVttCueBlock {
    param(
        [string[]]$Lines,
        [int]$StartingLine,
        [int]$SourceIndex
    )

    $timingIndex = -1
    $timingMatch = $null
    $timingPattern = "^(?<start>$($script:TimestampPattern))(?<beforeArrow>[ `t`f]+)-->(?<afterArrow>[ `t`f]+)(?<end>$($script:TimestampPattern))(?<suffix>(?:[ `t`f]+.*)?)$"

    for ($candidateIndex = 0; $candidateIndex -le 1 -and $candidateIndex -lt $Lines.Length; $candidateIndex++) {
        $candidate = [string]$Lines[$candidateIndex]
        $candidateMatch = [System.Text.RegularExpressions.Regex]::Match(
            $candidate,
            $timingPattern,
            [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
        )
        if ($candidateMatch.Success) {
            $timingIndex = $candidateIndex
            $timingMatch = $candidateMatch
            break
        }
        if ($candidate.Contains('-->')) {
            throw "Invalid WebVTT cue timing at line $($StartingLine + $candidateIndex): $(Get-SanitizedBlockExcerpt @($candidate))"
        }
    }

    if ($timingIndex -lt 0) {
        return $null
    }

    if ($timingIndex -eq 1) {
        if ([string]::IsNullOrEmpty($Lines[0]) -or $Lines[0].Contains('-->')) {
            throw "Invalid WebVTT cue identifier at line $StartingLine"
        }
        $identifier = [string]$Lines[0]
    }
    else {
        $identifier = $null
    }

    $timingLineNumber = $StartingLine + $timingIndex
    $startText = $timingMatch.Groups['start'].Value
    $endText = $timingMatch.Groups['end'].Value
    $startMilliseconds = ConvertFrom-WebVttTimestamp $startText $timingLineNumber
    $endMilliseconds = ConvertFrom-WebVttTimestamp $endText $timingLineNumber
    if ($endMilliseconds -le $startMilliseconds) {
        throw "WebVTT cue end must be greater than start at line $timingLineNumber"
    }

    $payloadLines = New-Object System.Collections.ArrayList
    for ($payloadIndex = $timingIndex + 1; $payloadIndex -lt $Lines.Length; $payloadIndex++) {
        [void]$payloadLines.Add([string]$Lines[$payloadIndex])
    }

    return [pscustomobject]@{
        Type = 'Cue'
        StartingLine = $StartingLine
        SourceIndex = $SourceIndex
        Lines = @($Lines)
        Identifier = $identifier
        TimingIndex = $timingIndex
        TimingLineNumber = $timingLineNumber
        StartText = $startText
        EndText = $endText
        StartMilliseconds = [int64]$startMilliseconds
        EndMilliseconds = [int64]$endMilliseconds
        EndTokenIndex = $timingMatch.Groups['end'].Index
        EndTokenLength = $timingMatch.Groups['end'].Length
        PayloadLines = @($payloadLines)
        Clipped = $false
    }
}

function Read-WebVttDocument {
    param([string]$Content)

    $normalized = $Content.Replace("`r`n", "`n").Replace("`r", "`n")
    $lines = $normalized.Split([char]"`n")
    if ($lines.Length -eq 0 -or -not (Test-WebVttHeader $lines[0])) {
        throw 'Invalid WEBVTT header'
    }

    $headerLines = New-Object System.Collections.ArrayList
    [void]$headerLines.Add([string]$lines[0])
    $lineIndex = 1
    while ($lineIndex -lt $lines.Length -and $lines[$lineIndex].Length -gt 0) {
        if ($lines[$lineIndex].Contains('-->')) {
            throw "Missing blank line before WebVTT cue-like content at line $($lineIndex + 1)"
        }
        [void]$headerLines.Add([string]$lines[$lineIndex])
        $lineIndex++
    }
    while ($lineIndex -lt $lines.Length -and $lines[$lineIndex].Length -eq 0) {
        $lineIndex++
    }

    $blocks = New-Object System.Collections.ArrayList
    $cues = New-Object System.Collections.ArrayList
    $styleAndRegionBlocks = New-Object System.Collections.ArrayList
    $noteBlocks = New-Object System.Collections.ArrayList
    $sourceIndex = 0
    $seenCue = $false
    $previousCue = $null

    while ($lineIndex -lt $lines.Length) {
        $startingLine = $lineIndex + 1
        $blockLines = New-Object System.Collections.ArrayList
        while ($lineIndex -lt $lines.Length -and $lines[$lineIndex].Length -gt 0) {
            [void]$blockLines.Add([string]$lines[$lineIndex])
            $lineIndex++
        }
        while ($lineIndex -lt $lines.Length -and $lines[$lineIndex].Length -eq 0) {
            $lineIndex++
        }
        if ($blockLines.Count -eq 0) {
            continue
        }

        $blockLineArray = @($blockLines)
        $firstLine = [string]$blockLineArray[0]
        if (
            $firstLine -eq 'NOTE' -or
            $firstLine.StartsWith('NOTE ') -or
            $firstLine.StartsWith("NOTE`t")
        ) {
            $block = [pscustomobject]@{
                Type = 'NOTE'
                StartingLine = $startingLine
                SourceIndex = $sourceIndex
                Lines = $blockLineArray
            }
            [void]$blocks.Add($block)
            [void]$noteBlocks.Add($block)
            $sourceIndex++
            continue
        }

        $cue = ConvertFrom-WebVttCueBlock $blockLineArray $startingLine $sourceIndex
        if ($null -ne $cue) {
            if ($null -ne $previousCue -and $cue.StartMilliseconds -lt $previousCue.StartMilliseconds) {
                throw "Out-of-order WebVTT cue at line $($cue.StartingLine): start $($cue.StartText) is earlier than previous cue start $($previousCue.StartText)"
            }
            [void]$blocks.Add($cue)
            [void]$cues.Add($cue)
            $previousCue = $cue
            $seenCue = $true
            $sourceIndex++
            continue
        }

        $metadataType = $null
        if ([System.Text.RegularExpressions.Regex]::IsMatch($firstLine, '^STYLE[ \t]*$')) {
            $metadataType = 'STYLE'
        }
        elseif ([System.Text.RegularExpressions.Regex]::IsMatch($firstLine, '^REGION[ \t]*$')) {
            $metadataType = 'REGION'
        }
        if ($null -ne $metadataType) {
            if ($seenCue) {
                throw "$metadataType block at line $startingLine appears after cue content"
            }
            $block = [pscustomobject]@{
                Type = $metadataType
                StartingLine = $startingLine
                SourceIndex = $sourceIndex
                Lines = $blockLineArray
            }
            [void]$blocks.Add($block)
            [void]$styleAndRegionBlocks.Add($block)
            $sourceIndex++
            continue
        }

        $excerpt = Get-SanitizedBlockExcerpt $blockLineArray
        throw "Unrecognized WebVTT block beginning at line $startingLine`: $excerpt"
    }

    return [pscustomobject]@{
        HeaderLines = @($headerLines)
        Blocks = @($blocks)
        Cues = @($cues)
        StyleAndRegionBlocks = @($styleAndRegionBlocks)
        NoteBlocks = @($noteBlocks)
    }
}

function Copy-ClippedCue {
    param(
        $Cue,
        [int64]$DurationMilliseconds
    )

    $lines = @($Cue.Lines)
    $timingLine = [string]$lines[$Cue.TimingIndex]
    $formattedEnd = Format-WebVttTimestamp $DurationMilliseconds
    $lines[$Cue.TimingIndex] = (
        $timingLine.Substring(0, $Cue.EndTokenIndex) +
        $formattedEnd +
        $timingLine.Substring($Cue.EndTokenIndex + $Cue.EndTokenLength)
    )
    return [pscustomobject]@{
        Type = 'Cue'
        StartingLine = $Cue.StartingLine
        SourceIndex = $Cue.SourceIndex
        Lines = $lines
        Identifier = $Cue.Identifier
        TimingIndex = $Cue.TimingIndex
        TimingLineNumber = $Cue.TimingLineNumber
        StartText = $Cue.StartText
        EndText = $formattedEnd
        StartMilliseconds = $Cue.StartMilliseconds
        EndMilliseconds = $DurationMilliseconds
        EndTokenIndex = $Cue.EndTokenIndex
        EndTokenLength = $formattedEnd.Length
        PayloadLines = $Cue.PayloadLines
        Clipped = $true
    }
}

function Get-RetainedCues {
    param(
        [object[]]$Cues,
        [int64]$DurationMilliseconds
    )

    $retained = New-Object System.Collections.ArrayList
    $removedCount = 0
    $clippedCount = 0
    foreach ($cue in $Cues) {
        if ($cue.StartMilliseconds -ge $DurationMilliseconds) {
            $removedCount++
            continue
        }
        if ($cue.EndMilliseconds -gt $DurationMilliseconds) {
            [void]$retained.Add((Copy-ClippedCue $cue $DurationMilliseconds))
            $clippedCount++
            continue
        }
        [void]$retained.Add($cue)
    }

    return [pscustomobject]@{
        Cues = @($retained)
        RemovedCount = $removedCount
        ClippedCount = $clippedCount
    }
}

function Get-CoveredTimelineUnion {
    param([object[]]$Cues)

    $covered = New-Object System.Collections.ArrayList
    foreach ($cue in $Cues) {
        if ($covered.Count -eq 0) {
            [void]$covered.Add([pscustomobject]@{
                Start = [int64]$cue.StartMilliseconds
                End = [int64]$cue.EndMilliseconds
            })
            continue
        }

        $last = $covered[$covered.Count - 1]
        if ($cue.StartMilliseconds -le $last.End) {
            if ($cue.EndMilliseconds -gt $last.End) {
                $last.End = [int64]$cue.EndMilliseconds
            }
        }
        else {
            [void]$covered.Add([pscustomobject]@{
                Start = [int64]$cue.StartMilliseconds
                End = [int64]$cue.EndMilliseconds
            })
        }
    }
    return ,@($covered)
}

function Get-UncoveredTimelineIntervals {
    param(
        [object[]]$CoveredIntervals,
        [int64]$DurationMilliseconds
    )

    $uncovered = New-Object System.Collections.ArrayList
    $cursor = 0L
    foreach ($interval in $CoveredIntervals) {
        if ($cursor -lt $interval.Start) {
            [void]$uncovered.Add([pscustomobject]@{
                Start = $cursor
                End = [int64]$interval.Start
            })
        }
        if ($interval.End -gt $cursor) {
            $cursor = [int64]$interval.End
        }
    }
    if ($cursor -lt $DurationMilliseconds) {
        [void]$uncovered.Add([pscustomobject]@{
            Start = $cursor
            End = $DurationMilliseconds
        })
    }
    return ,@($uncovered)
}

function Assert-CoverageCueLimit {
    param(
        [object[]]$UncoveredIntervals,
        [int64]$CueIntervalMilliseconds
    )

    $totalCueCount = 0L
    foreach ($interval in $UncoveredIntervals) {
        $intervalLength = [int64]$interval.End - [int64]$interval.Start
        $remainder = 0L
        $intervalCueCount = [System.Math]::DivRem(
            $intervalLength,
            $CueIntervalMilliseconds,
            [ref]$remainder
        )
        if ($remainder -ne 0L) {
            $intervalCueCount++
        }
        if ($intervalCueCount -gt ($script:MaximumGeneratedCues - $totalCueCount)) {
            throw "Requested timeline would generate more than $($script:MaximumGeneratedCues) coverage cues"
        }
        $totalCueCount += $intervalCueCount
    }
}

function New-CoverageCues {
    param(
        [object[]]$UncoveredIntervals,
        [int64]$CueIntervalMilliseconds
    )

    Assert-CoverageCueLimit $UncoveredIntervals $CueIntervalMilliseconds
    $generated = New-Object System.Collections.ArrayList
    $generatedCount = 0L
    foreach ($interval in $UncoveredIntervals) {
        $start = [int64]$interval.Start
        while ($start -lt $interval.End) {
            $remaining = [int64]$interval.End - $start
            if ($remaining -lt $CueIntervalMilliseconds) {
                $step = $remaining
            }
            else {
                $step = $CueIntervalMilliseconds
            }
            $end = $start + $step
            $generatedCount++
            [void]$generated.Add([pscustomobject]@{
                Type = 'GeneratedCue'
                StartMilliseconds = $start
                EndMilliseconds = $end
                Lines = @(
                    "$(Format-WebVttTimestamp $start) --> $(Format-WebVttTimestamp $end)",
                    [string][char]0x2060
                )
            })
            $start = $end
        }
    }
    return ,@($generated)
}

function Get-NoteTargets {
    param(
        [object[]]$Notes,
        [object[]]$RetainedCues
    )

    $targets = @{}
    $trailing = New-Object System.Collections.ArrayList
    foreach ($note in $Notes) {
        $target = $null
        foreach ($cue in $RetainedCues) {
            if ($cue.SourceIndex -gt $note.SourceIndex) {
                $target = $cue
                break
            }
        }
        if ($null -eq $target) {
            [void]$trailing.Add($note)
            continue
        }

        $key = [string]$target.SourceIndex
        if (-not $targets.ContainsKey($key)) {
            $targets[$key] = New-Object System.Collections.ArrayList
        }
        [void]$targets[$key].Add($note)
    }

    return [pscustomobject]@{
        ByCueSourceIndex = $targets
        Trailing = @($trailing)
    }
}

function Serialize-WebVttDocument {
    param(
        $Document,
        [object[]]$RetainedCues,
        [object[]]$GeneratedCues
    )

    $outputBlocks = New-Object System.Collections.ArrayList
    [void]$outputBlocks.Add(($Document.HeaderLines -join "`n"))
    foreach ($metadataBlock in $Document.StyleAndRegionBlocks) {
        [void]$outputBlocks.Add(($metadataBlock.Lines -join "`n"))
    }

    $noteTargets = Get-NoteTargets $Document.NoteBlocks $RetainedCues
    $generatedIndex = 0
    foreach ($cue in $RetainedCues) {
        while (
            $generatedIndex -lt $GeneratedCues.Count -and
            $GeneratedCues[$generatedIndex].EndMilliseconds -le $cue.StartMilliseconds
        ) {
            [void]$outputBlocks.Add(($GeneratedCues[$generatedIndex].Lines -join "`n"))
            $generatedIndex++
        }

        $cueKey = [string]$cue.SourceIndex
        if ($noteTargets.ByCueSourceIndex.ContainsKey($cueKey)) {
            foreach ($note in $noteTargets.ByCueSourceIndex[$cueKey]) {
                [void]$outputBlocks.Add(($note.Lines -join "`n"))
            }
        }
        [void]$outputBlocks.Add(($cue.Lines -join "`n"))
    }

    while ($generatedIndex -lt $GeneratedCues.Count) {
        [void]$outputBlocks.Add(($GeneratedCues[$generatedIndex].Lines -join "`n"))
        $generatedIndex++
    }
    foreach ($note in $noteTargets.Trailing) {
        [void]$outputBlocks.Add(($note.Lines -join "`n"))
    }

    return ($outputBlocks -join "`n`n") + "`n"
}

function Write-WebVttAtomically {
    param(
        [string]$TargetPath,
        [string]$Content
    )

    $directory = [System.IO.Path]::GetDirectoryName($TargetPath)
    $fileName = [System.IO.Path]::GetFileName($TargetPath)
    $operationId = [Guid]::NewGuid().ToString('N')
    $temporaryPath = [System.IO.Path]::Combine($directory, ".$fileName.$operationId.tmp")
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
            # NullString.Value passes an actual null string through the Windows
            # PowerShell 5.1 method binder. Plain $null becomes an illegal empty
            # backup path on that runtime.
            [System.IO.File]::Replace(
                $temporaryPath,
                $TargetPath,
                [System.Management.Automation.Language.NullString]::Value
            )
        }
        else {
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

    $durationValue = ConvertTo-InvariantPositiveDouble $DurationSeconds 'DurationSeconds'
    $intervalValue = ConvertTo-InvariantPositiveDouble $CueIntervalSeconds 'CueIntervalSeconds'
    $durationMilliseconds = ConvertTo-PositiveMilliseconds $durationValue 'DurationSeconds'
    $cueIntervalMilliseconds = ConvertTo-PositiveMilliseconds $intervalValue 'CueIntervalSeconds'

    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $content = [System.IO.File]::ReadAllText($fullPath, $strictUtf8)
    $document = Read-WebVttDocument $content

    # All parsing and validation above completes before clipping, normalization,
    # serialization, or creation of any temporary output file.
    $retention = Get-RetainedCues $document.Cues $durationMilliseconds
    $covered = Get-CoveredTimelineUnion $retention.Cues
    $uncovered = Get-UncoveredTimelineIntervals $covered $durationMilliseconds
    $generated = New-CoverageCues $uncovered $cueIntervalMilliseconds

    $hasSemanticChange = (
        $retention.RemovedCount -gt 0 -or
        $retention.ClippedCount -gt 0 -or
        $generated.Count -gt 0
    )
    if ($hasSemanticChange) {
        $normalizedContent = Serialize-WebVttDocument $document $retention.Cues $generated
        Write-WebVttAtomically $fullPath $normalizedContent
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
