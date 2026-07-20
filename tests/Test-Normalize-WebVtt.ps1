[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0
$script:Failures = New-Object 'System.Collections.Generic.List[string]'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$productionScript = Join-Path $repoRoot 'Normalize-WebVtt.ps1'
$batchScript = Join-Path $repoRoot 'Normalize-WebVtt.bat'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('webvtt-timeline-tests-' + [Guid]::NewGuid().ToString('N'))
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$wordJoiner = [string][char]0x2060
$script:PowerShellExecutable = (Get-Process -Id $PID).Path
if ([string]::IsNullOrWhiteSpace($script:PowerShellExecutable)) {
    throw 'Unable to determine the current PowerShell executable path'
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-False {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "$Message (expected '$Expected', actual '$Actual')"
    }
}

function Assert-Contains {
    param([string]$Value, [string]$Expected, [string]$Message)
    if (-not $Value.Contains($Expected)) {
        throw "$Message (missing '$Expected')"
    }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        [Console]::WriteLine("PASS $Name")
    }
    catch {
        $script:Failed++
        $detail = $_.Exception.Message -replace '[\r\n]+', ' '
        $script:Failures.Add("$Name`: $detail")
        [Console]::WriteLine("FAIL $Name - $detail")
    }
}

function Skip-Test {
    param([string]$Name, [string]$Reason)
    $script:Skipped++
    [Console]::WriteLine("SKIP $Name - $Reason")
}

function New-TestFile {
    param(
        [string]$RelativePath,
        [string]$Content,
        [switch]$Bom
    )

    $path = Join-Path $tempRoot $RelativePath
    $directory = [System.IO.Path]::GetDirectoryName($path)
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    if ($Bom) {
        $encoding = New-Object System.Text.UTF8Encoding($true)
    }
    else {
        $encoding = $utf8NoBom
    }
    [System.IO.File]::WriteAllText($path, $Content, $encoding)
    return $path
}

function ConvertTo-SingleQuotedLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-Normalizer {
    param(
        [string]$Path,
        [string]$Duration = '13.2',
        [string]$Interval = '6',
        [string]$Culture
    )

    $stderrPath = Join-Path $tempRoot ('stderr-' + [Guid]::NewGuid().ToString('N') + '.txt')
    if ([string]::IsNullOrEmpty($Culture)) {
        $stdout = @(
            & $script:PowerShellExecutable -NoLogo -NoProfile -NonInteractive -File $productionScript `
                -VttPath $Path `
                -DurationSeconds $Duration `
                -CueIntervalSeconds $Interval 2> $stderrPath
        )
    }
    else {
        $command = @(
            "[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($(ConvertTo-SingleQuotedLiteral $Culture))"
            "& $(ConvertTo-SingleQuotedLiteral $productionScript) -VttPath $(ConvertTo-SingleQuotedLiteral $Path) -DurationSeconds $(ConvertTo-SingleQuotedLiteral $Duration) -CueIntervalSeconds $(ConvertTo-SingleQuotedLiteral $Interval)"
            'exit $LASTEXITCODE'
        ) -join '; '
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $stdout = @(& $script:PowerShellExecutable -NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded 2> $stderrPath)
    }

    $exitCode = $LASTEXITCODE
    if ([System.IO.File]::Exists($stderrPath)) {
        $stderr = [System.IO.File]::ReadAllText($stderrPath)
        [System.IO.File]::Delete($stderrPath)
    }
    else {
        $stderr = ''
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Lines = $stdout
        StdErr = $stderr
    }
}

function Assert-Result {
    param(
        $Result,
        [int]$ExitCode,
        [string]$ExactLine,
        [string]$Contains
    )

    Assert-Equal $ExitCode $Result.ExitCode 'Unexpected process exit code'
    Assert-Equal 1 $Result.Lines.Count 'Standard output must contain exactly one line'
    if (-not [string]::IsNullOrEmpty($ExactLine)) {
        Assert-Equal $ExactLine ([string]$Result.Lines[0]) 'Unexpected RESULT line'
    }
    if (-not [string]::IsNullOrEmpty($Contains)) {
        Assert-Contains ([string]$Result.Lines[0]) $Contains 'Unexpected RESULT error text'
    }
}

function Convert-TestTimestampToMilliseconds {
    param([string]$Timestamp)

    $match = [regex]::Match(
        $Timestamp,
        '^(?:(?<hours>[0-9]{2,}):)?(?<minutes>[0-9]{2}):(?<seconds>[0-9]{2})\.(?<milliseconds>[0-9]{3})$'
    )
    if (-not $match.Success) {
        throw "Invalid test timestamp: $Timestamp"
    }
    if ($match.Groups['hours'].Success) {
        $hours = [int64]$match.Groups['hours'].Value
    }
    else {
        $hours = 0L
    }
    return (
        ($hours * 3600000L) +
        ([int64]$match.Groups['minutes'].Value * 60000L) +
        ([int64]$match.Groups['seconds'].Value * 1000L) +
        [int64]$match.Groups['milliseconds'].Value
    )
}

function Get-TestDocument {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $content = $utf8NoBom.GetString($bytes)
    if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) {
        $content = $content.Substring(1)
    }
    $normalized = $content.Replace("`r`n", "`n").Replace("`r", "`n")
    $lines = $normalized.Split([char]"`n")
    $cues = New-Object System.Collections.ArrayList
    $metadata = New-Object System.Collections.ArrayList

    $index = 1
    while ($index -lt $lines.Length -and $lines[$index].Length -gt 0) {
        $index++
    }
    while ($index -lt $lines.Length -and $lines[$index].Length -eq 0) {
        $index++
    }

    while ($index -lt $lines.Length) {
        $blockLines = New-Object System.Collections.ArrayList
        while ($index -lt $lines.Length -and $lines[$index].Length -gt 0) {
            [void]$blockLines.Add($lines[$index])
            $index++
        }
        while ($index -lt $lines.Length -and $lines[$index].Length -eq 0) {
            $index++
        }
        if ($blockLines.Count -eq 0) {
            continue
        }

        $firstLine = [string]$blockLines[0]
        if (
            $firstLine -eq 'NOTE' -or
            $firstLine.StartsWith('NOTE ') -or
            $firstLine.StartsWith("NOTE`t")
        ) {
            [void]$metadata.Add(($blockLines -join "`n"))
            continue
        }

        $timingIndex = -1
        if ([regex]::IsMatch($blockLines[0], '-->')) {
            $timingIndex = 0
        }
        elseif ($blockLines.Count -ge 2 -and [regex]::IsMatch($blockLines[1], '-->')) {
            $timingIndex = 1
        }

        if ($timingIndex -lt 0) {
            if (
                [regex]::IsMatch($firstLine, '^STYLE[ \t]*$') -or
                [regex]::IsMatch($firstLine, '^REGION[ \t]*$')
            ) {
                [void]$metadata.Add(($blockLines -join "`n"))
                continue
            }
            [void]$metadata.Add(($blockLines -join "`n"))
            continue
        }

        $timing = [regex]::Match(
            $blockLines[$timingIndex],
            '^(?<start>(?:[0-9]{2,}:)?[0-9]{2}:[0-9]{2}\.[0-9]{3})[ 	\f]+-->[ 	\f]+(?<end>(?:[0-9]{2,}:)?[0-9]{2}:[0-9]{2}\.[0-9]{3})(?<settings>.*)$'
        )
        if (-not $timing.Success) {
            throw "Test parser could not parse timing line: $($blockLines[$timingIndex])"
        }
        if ($timingIndex -eq 1) {
            $identifier = [string]$blockLines[0]
        }
        else {
            $identifier = $null
        }
        $payload = New-Object System.Collections.ArrayList
        for ($payloadIndex = $timingIndex + 1; $payloadIndex -lt $blockLines.Count; $payloadIndex++) {
            [void]$payload.Add([string]$blockLines[$payloadIndex])
        }
        [void]$cues.Add([pscustomobject]@{
            Identifier = $identifier
            Start = Convert-TestTimestampToMilliseconds $timing.Groups['start'].Value
            End = Convert-TestTimestampToMilliseconds $timing.Groups['end'].Value
            TimingLine = [string]$blockLines[$timingIndex]
            Settings = $timing.Groups['settings'].Value
            Payload = @($payload)
            Generated = ($null -eq $identifier -and $payload.Count -eq 1 -and $payload[0] -eq $wordJoiner)
        })
    }

    return [pscustomobject]@{
        Bytes = $bytes
        Content = $content
        Normalized = $normalized
        Cues = @($cues)
        Metadata = @($metadata)
    }
}

function Assert-GeneratedCue {
    param($Cue, [int64]$MaximumInterval, [int64]$Duration)

    Assert-True $Cue.Generated 'Expected a generated U+2060 cue'
    Assert-True ($null -eq $Cue.Identifier) 'Generated cue must not have an identifier'
    Assert-Equal 1 $Cue.Payload.Count 'Generated cue must have exactly one payload line'
    Assert-Equal $wordJoiner ([string]$Cue.Payload[0]) 'Generated cue payload must be exactly one U+2060'
    Assert-True ($Cue.Start -lt $Cue.End) 'Generated cue must have positive duration'
    Assert-True (($Cue.End - $Cue.Start) -le $MaximumInterval) 'Generated cue exceeds requested interval'
    Assert-True ($Cue.End -le $Duration) 'Generated cue extends beyond video duration'
    Assert-False $Cue.TimingLine.Contains('<i>') 'Generated timing line contains italics'
}

function Assert-CueRanges {
    param($Cues, [object[]]$ExpectedRanges)

    if ($ExpectedRanges.Count -eq 2 -and -not ($ExpectedRanges[0] -is [System.Array])) {
        $ExpectedRanges = ,@($ExpectedRanges)
    }
    Assert-Equal $ExpectedRanges.Count $Cues.Count 'Unexpected cue count'
    for ($index = 0; $index -lt $ExpectedRanges.Count; $index++) {
        Assert-Equal ([int64]$ExpectedRanges[$index][0]) ([int64]$Cues[$index].Start) "Unexpected cue $($index + 1) start"
        Assert-Equal ([int64]$ExpectedRanges[$index][1]) ([int64]$Cues[$index].End) "Unexpected cue $($index + 1) end"
    }
}

function Assert-TimelineUnion {
    param($Cues, [int64]$Duration)

    $intervals = @($Cues | Sort-Object Start, End)
    Assert-True ($intervals.Count -gt 0) 'Timeline has no cue coverage'
    Assert-Equal 0L ([int64]$intervals[0].Start) 'Timeline coverage does not begin at zero'
    $coveredEnd = 0L
    foreach ($cue in $intervals) {
        Assert-True ($cue.Start -le $coveredEnd) "Timeline has a gap before $($cue.Start) ms"
        if ($cue.End -gt $coveredEnd) {
            $coveredEnd = $cue.End
        }
    }
    Assert-Equal $Duration $coveredEnd 'Timeline union does not end at video duration'

    $generated = @($Cues | Where-Object { $_.Generated })
    $existing = @($Cues | Where-Object { -not $_.Generated })
    foreach ($coverageCue in $generated) {
        foreach ($captionCue in $existing) {
            $overlaps = $coverageCue.Start -lt $captionCue.End -and $coverageCue.End -gt $captionCue.Start
            Assert-False $overlaps 'Generated cue overlaps existing caption coverage'
        }
    }
}

function Assert-NoTemporaryFiles {
    param([string]$Path)

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    $fileName = [System.IO.Path]::GetFileName($Path)
    $temporary = @(Get-ChildItem -LiteralPath $directory -Filter ".$fileName.*.tmp")
    $backups = @(Get-ChildItem -LiteralPath $directory -Filter ".$fileName.*.bak")
    Assert-Equal 0 $temporary.Count 'Temporary file was left behind'
    Assert-Equal 0 $backups.Count 'Backup file was left behind'
}

function Assert-FailureLeavesFileUntouched {
    param(
        [string]$Path,
        [string]$Duration,
        [string]$Interval,
        [string]$ExpectedMessage
    )

    $before = [System.IO.File]::ReadAllBytes($Path)
    $result = Invoke-Normalizer $Path $Duration $Interval
    Assert-Result $result 1 $null $ExpectedMessage
    $after = [System.IO.File]::ReadAllBytes($Path)
    Assert-True ([System.Linq.Enumerable]::SequenceEqual[byte]($before, $after)) 'Failure changed original file bytes'
    Assert-NoTemporaryFiles $Path
    return $result
}

function Assert-UnchangedSuccess {
    param(
        [string]$RelativePath,
        [string]$Content,
        [string]$Duration,
        [switch]$Bom
    )

    $path = New-TestFile $RelativePath $Content -Bom:$Bom
    $fixedTime = [DateTime]::UtcNow.AddMinutes(-10)
    [System.IO.File]::SetLastWriteTimeUtc($path, $fixedTime)
    $beforeBytes = [System.IO.File]::ReadAllBytes($path)
    $beforeTime = [System.IO.File]::GetLastWriteTimeUtc($path)
    $result = Invoke-Normalizer $path $Duration '6'
    Assert-Result $result 0 'RESULT=0' $null
    $afterBytes = [System.IO.File]::ReadAllBytes($path)
    Assert-True ([System.Linq.Enumerable]::SequenceEqual[byte]($beforeBytes, $afterBytes)) 'No-change file bytes changed'
    Assert-Equal $beforeTime ([System.IO.File]::GetLastWriteTimeUtc($path)) 'No-change file timestamp changed'
    Assert-NoTemporaryFiles $path
}

[System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
try {
    Invoke-Test 'production script exists' {
        Assert-True ([System.IO.File]::Exists($productionScript)) 'Normalize-WebVtt.ps1 is missing'
    }

    Invoke-Test 'header-only file ends at exact fractional duration' {
        $path = New-TestFile 'generation/header-only.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '13.2' '6') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        Assert-CueRanges $document.Cues @(@(0L, 6000L), @(6000L, 12000L), @(12000L, 13200L))
        foreach ($cue in $document.Cues) {
            Assert-GeneratedCue $cue 6000L 13200L
        }
    }

    Invoke-Test 'whole-second duration does not add an extra cue' {
        $path = New-TestFile 'generation/whole.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '31' '6') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        Assert-CueRanges $document.Cues @(
            @(0L, 6000L), @(6000L, 12000L), @(12000L, 18000L),
            @(18000L, 24000L), @(24000L, 30000L), @(30000L, 31000L)
        )
    }

    Invoke-Test 'fractional duration ends at 31.417 seconds' {
        $path = New-TestFile 'generation/fractional-duration.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '31.417' '6') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        Assert-Equal 31417L ([int64]$document.Cues[-1].End) 'Final cue must end at 31.417 seconds'
        Assert-False $document.Normalized.Contains('00:00:32.000') 'Duration was rounded upward to 32 seconds'
    }

    Invoke-Test 'fractional cue interval uses exact milliseconds' {
        $path = New-TestFile 'generation/fractional-interval.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '20' '6.5') 0 'RESULT=0' $null
        Assert-CueRanges (Get-TestDocument $path).Cues @(
            @(0L, 6500L), @(6500L, 13000L), @(13000L, 19500L), @(19500L, 20000L)
        )
    }

    Invoke-Test 'subsecond interval generates millisecond cues' {
        $path = New-TestFile 'generation/subsecond.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '1.1' '0.25') 0 'RESULT=0' $null
        Assert-CueRanges (Get-TestDocument $path).Cues @(
            @(0L, 250L), @(250L, 500L), @(500L, 750L), @(750L, 1000L), @(1000L, 1100L)
        )
    }

    Invoke-Test 'interval longer than video generates one exact cue' {
        $path = New-TestFile 'generation/long-interval.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '5.250' '30') 0 'RESULT=0' $null
        Assert-CueRanges (Get-TestDocument $path).Cues @(@(0L, 5250L))
    }

    Invoke-Test 'generated payload is exactly U+2060 without markup or identifiers' {
        $path = New-TestFile 'generation/payload.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '2' '0.75') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        foreach ($cue in $document.Cues) {
            Assert-GeneratedCue $cue 750L 2000L
        }
        foreach ($forbidden in @('<i>', '</i>', '<i> </i>', '<U+2060>', 'U+2060')) {
            Assert-False $document.Content.Contains($forbidden) "Generated output contains forbidden text $forbidden"
        }
    }

    Invoke-Test 'existing shorter cue is preserved and trailing coverage is appended' {
        $content = "WEBVTT`n`n00:00:00.000 --> 00:00:10.000`nCaption`n"
        $path = New-TestFile 'coverage/trailing.vtt' $content
        Assert-Result (Invoke-Normalizer $path '31' '6') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        Assert-Equal 'Caption' ([string]$document.Cues[0].Payload[0]) 'Existing payload changed'
        Assert-CueRanges $document.Cues @(
            @(0L, 10000L), @(10000L, 16000L), @(16000L, 22000L),
            @(22000L, 28000L), @(28000L, 31000L)
        )
        Assert-TimelineUnion $document.Cues 31000L
    }

    Invoke-Test 'coverage is generated before first cue' {
        $content = "WEBVTT`n`n00:00:05.000 --> 00:00:10.000`nCaption`n"
        $path = New-TestFile 'coverage/leading.vtt' $content
        Assert-Result (Invoke-Normalizer $path '10' '6') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        Assert-CueRanges $document.Cues @(@(0L, 5000L), @(5000L, 10000L))
        Assert-True $document.Cues[0].Generated 'Leading cue must be generated'
        Assert-False $document.Cues[1].Generated 'Caption cue must remain existing content'
    }

    Invoke-Test 'single internal gap is filled' {
        $content = "WEBVTT`n`n00:00:00.000 --> 00:00:04.000`nCaption A`n`n00:00:10.000 --> 00:00:15.000`nCaption B`n"
        $path = New-TestFile 'coverage/internal-gap.vtt' $content
        Assert-Result (Invoke-Normalizer $path '15' '6') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        Assert-CueRanges $document.Cues @(@(0L, 4000L), @(4000L, 10000L), @(10000L, 15000L))
        Assert-True $document.Cues[1].Generated 'Internal gap was not generated'
    }

    Invoke-Test 'large internal gap is split by interval' {
        $content = "WEBVTT`n`n00:00:00.000 --> 00:00:04.000`nCaption A`n`n00:00:20.000 --> 00:00:25.000`nCaption B`n"
        $path = New-TestFile 'coverage/large-gap.vtt' $content
        Assert-Result (Invoke-Normalizer $path '25' '6') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        Assert-CueRanges $document.Cues @(
            @(0L, 4000L), @(4000L, 10000L), @(10000L, 16000L),
            @(16000L, 20000L), @(20000L, 25000L)
        )
    }

    Invoke-Test 'overlapping cues use interval union without false gap' {
        $content = "WEBVTT`n`n00:00:02.000 --> 00:00:08.000`nCaption A`n`n00:00:05.000 --> 00:00:10.000`nCaption B`n"
        $path = New-TestFile 'coverage/overlap.vtt' $content
        Assert-Result (Invoke-Normalizer $path '12' '6') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        Assert-CueRanges $document.Cues @(@(0L, 2000L), @(2000L, 8000L), @(5000L, 10000L), @(10000L, 12000L))
        Assert-Equal 'Caption A' ([string]$document.Cues[1].Payload[0]) 'First overlap payload changed'
        Assert-Equal 'Caption B' ([string]$document.Cues[2].Payload[0]) 'Second overlap payload changed'
        Assert-Equal 0 @($document.Cues | Where-Object { $_.Generated -and $_.Start -eq 8000L }).Count 'False 8-10 gap was generated'
        Assert-TimelineUnion $document.Cues 12000L
    }

    Invoke-Test 'cue extending past video is clipped' {
        $content = "WEBVTT`n`n00:00:25.000 --> 00:00:35.000`nFinal caption`n"
        $path = New-TestFile 'clipping/basic.vtt' $content
        Assert-Result (Invoke-Normalizer $path '31' '6') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        Assert-Equal 31000L ([int64]$document.Cues[-1].End) 'Clipped cue did not end at video duration'
        Assert-Equal 'Final caption' ([string]$document.Cues[-1].Payload[0]) 'Clipped cue payload changed'
    }

    Invoke-Test 'clipping replaces only end timestamp token' {
        $timing = "00:00:25.000 `t-->  00:00:35.000 align:center line:10% position:50% size:50%"
        $content = "WEBVTT`n`nFinal-ID`n$timing`nFinal caption`n"
        $path = New-TestFile 'clipping/settings.vtt' $content
        Assert-Result (Invoke-Normalizer $path '31' '6') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        $expected = "00:00:25.000 `t-->  00:00:31.000 align:center line:10% position:50% size:50%"
        Assert-Equal $expected $document.Cues[-1].TimingLine 'Clipping changed more than the end timestamp'
        Assert-Equal 'Final-ID' $document.Cues[-1].Identifier 'Clipping changed cue identifier'
    }

    Invoke-Test 'cue beginning at or after video is removed and gap is filled' {
        $content = "WEBVTT`n`n00:00:00.000 --> 00:00:05.000`nKeep`n`n00:00:10.000 --> 00:00:12.000`nRemove at duration`n`n00:00:12.000 --> 00:00:14.000`nRemove later`n"
        $path = New-TestFile 'clipping/remove-outside.vtt' $content
        Assert-Result (Invoke-Normalizer $path '10' '3') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        Assert-False $document.Content.Contains('Remove at duration') 'Cue starting at duration was retained'
        Assert-False $document.Content.Contains('Remove later') 'Cue after duration was retained'
        Assert-TimelineUnion $document.Cues 10000L
    }

    Invoke-Test 'complete existing coverage leaves bytes and timestamp unchanged' {
        $content = "WEBVTT Generated upstream`r`n`r`nA`r`n00:00:00.000 --> 00:00:07.000`r`n<i>Caption A</i>`r`n`r`nB`r`n00:00:07.000 --> 00:00:10.000 align:center`r`nCaption B`r`n"
        Assert-UnchangedSuccess 'no-change/full.vtt' $content '10'
    }

    Invoke-Test 'existing identifiers are preserved and generated cues have none' {
        $content = "WEBVTT`n`ncaption-id`n00:00:02.000 --> 00:00:04.000`nCaption`n"
        $path = New-TestFile 'preservation/identifier.vtt' $content
        Assert-Result (Invoke-Normalizer $path '6' '6') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        $existing = @($document.Cues | Where-Object { -not $_.Generated })
        $generated = @($document.Cues | Where-Object { $_.Generated })
        Assert-Equal 'caption-id' $existing[0].Identifier 'Existing identifier changed'
        foreach ($cue in $generated) {
            Assert-True ($null -eq $cue.Identifier) 'Generated cue received an identifier'
        }
    }

    Invoke-Test 'existing inline markup and multiline payload are preserved' {
        $content = "WEBVTT`n`n00:00:01.000 --> 00:00:03.000`n<i>Caption</i>`n<v Speaker>Second line</v>`n"
        $path = New-TestFile 'preservation/markup.vtt' $content
        Assert-Result (Invoke-Normalizer $path '4' '2') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        $existing = @($document.Cues | Where-Object { -not $_.Generated })[0]
        Assert-Equal '<i>Caption</i>' ([string]$existing.Payload[0]) 'Inline markup changed'
        Assert-Equal '<v Speaker>Second line</v>' ([string]$existing.Payload[1]) 'Multiline payload changed'
    }

    Invoke-Test 'existing cue with zero payload lines is preserved' {
        $content = "WEBVTT`n`n00:00:00.000 --> 00:00:02.000`n`n00:00:02.000 --> 00:00:03.000`nCaption`n"
        $path = New-TestFile 'preservation/blank-payload.vtt' $content
        Assert-Result (Invoke-Normalizer $path '4' '2') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        Assert-Equal 0 $document.Cues[0].Payload.Count 'Blank existing payload was replaced'
        Assert-False $document.Cues[0].Generated 'Blank existing cue became generated coverage'
    }

    Invoke-Test 'existing whitespace-only payload line is preserved' {
        $content = "WEBVTT`n`n00:00:00.000 --> 00:00:02.000`n   `n`n00:00:02.000 --> 00:00:03.000`nCaption`n"
        $path = New-TestFile 'preservation/whitespace-payload.vtt' $content
        Assert-Result (Invoke-Normalizer $path '4' '2') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        Assert-Equal '   ' ([string]$document.Cues[0].Payload[0]) 'Whitespace-only payload changed'
        Assert-False $document.Cues[0].Generated 'Whitespace existing cue became generated coverage'
    }

    Invoke-Test 'short MM SS timestamps are parsed and preserved' {
        $content = "WEBVTT`n`nshort`n00:01.250 --> 00:02.750 align:center`nCaption`n"
        $path = New-TestFile 'preservation/short-timestamps.vtt' $content
        Assert-Result (Invoke-Normalizer $path '3' '1') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        $existing = @($document.Cues | Where-Object { -not $_.Generated })[0]
        Assert-Equal '00:01.250 --> 00:02.750 align:center' $existing.TimingLine 'Short timing line changed'
        Assert-Equal 1250L ([int64]$existing.Start) 'Short start timestamp parsed incorrectly'
        Assert-Equal 2750L ([int64]$existing.End) 'Short end timestamp parsed incorrectly'
    }

    Invoke-Test 'NOTE arrow is preserved and not parsed as cue' {
        $content = "WEBVTT`n`nNOTE source --> destination`nsecond note line`n`n00:00:02.000 --> 00:00:03.000`nCaption`n"
        $path = New-TestFile 'metadata/note-arrow.vtt' $content
        Assert-Result (Invoke-Normalizer $path '4' '2') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        Assert-Contains $document.Content 'NOTE source --> destination' 'NOTE block was discarded'
        Assert-Equal 3 $document.Cues.Count 'NOTE arrow was parsed as a cue'
    }

    Invoke-Test 'STYLE and REGION before cues are preserved' {
        $content = "WEBVTT`n`nSTYLE`n::cue { color: lime; }`n`nREGION`nid:fred`nwidth:40%`n`n00:00:02.000 --> 00:00:03.000`nCaption`n"
        $path = New-TestFile 'metadata/style-region.vtt' $content
        Assert-Result (Invoke-Normalizer $path '4' '2') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        Assert-Contains $document.Content "STYLE`n::cue { color: lime; }" 'STYLE block was not preserved'
        Assert-Contains $document.Content "REGION`nid:fred`nwidth:40%" 'REGION block was not preserved'
        Assert-True ($document.Content.IndexOf('STYLE') -lt $document.Content.IndexOf('-->')) 'STYLE moved after cue content'
        Assert-True ($document.Content.IndexOf('REGION') -lt $document.Content.IndexOf('-->')) 'REGION moved after cue content'
    }

    Invoke-Test 'STYLE and REGION keywords allow trailing WebVTT whitespace' {
        $content = "WEBVTT`n`nSTYLE `t`n::cue { color: lime; }`n`nREGION`t`nid:fred`nwidth:40%`n`n00:00:00.000 --> 00:00:01.000`nCaption`n"
        $path = New-TestFile 'metadata/style-region-whitespace.vtt' $content
        Assert-Result (Invoke-Normalizer $path '2' '1') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        Assert-Contains $document.Content "STYLE `t`n::cue { color: lime; }" 'STYLE with trailing whitespace was not preserved'
        Assert-Contains $document.Content "REGION`t`nid:fred" 'REGION with trailing whitespace was not preserved'
    }

    Invoke-Test 'STYLE and REGION cue identifiers are preserved as cues' {
        $content = "WEBVTT`n`nSTYLE`n00:00:00.000 --> 00:00:01.000`nStyle identifier caption`n`nREGION`n00:00:01.000 --> 00:00:02.000`nRegion identifier caption`n"
        $path = New-TestFile 'metadata/style-region-identifiers.vtt' $content
        Assert-Result (Invoke-Normalizer $path '3' '1') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        $existing = @($document.Cues | Where-Object { -not $_.Generated })
        Assert-Equal 2 $existing.Count 'STYLE or REGION identifier cue was not parsed'
        Assert-Equal 'STYLE' $existing[0].Identifier 'STYLE cue identifier changed'
        Assert-Equal 'REGION' $existing[1].Identifier 'REGION cue identifier changed'
        Assert-Equal 'Style identifier caption' ([string]$existing[0].Payload[0]) 'STYLE identifier payload changed'
        Assert-Equal 'Region identifier caption' ([string]$existing[1].Payload[0]) 'REGION identifier payload changed'
    }

    Invoke-Test 'NOTE anchored to removed cue moves before next retained cue' {
        $content = "WEBVTT`n`nNOTE before removed`n`n00:00:12.000 --> 00:00:14.000`nRemoved`n`nNOTE before retained`n`n00:00:15.000 --> 00:00:17.000`nAlso removed`n"
        $path = New-TestFile 'metadata/note-removed-anchor.vtt' $content
        Assert-Result (Invoke-Normalizer $path '10' '5') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        Assert-Contains $document.Content 'NOTE before removed' 'NOTE anchored to removed cue was discarded'
        Assert-Contains $document.Content 'NOTE before retained' 'Trailing NOTE was discarded'
        Assert-False $document.Content.Contains('Removed') 'Outside cue payload was retained'
    }

    Invoke-Test 'header metadata is preserved before blocks' {
        $content = "WEBVTT Generated`nKind: captions`nLanguage: en`n`n00:00:01.000 --> 00:00:02.000`nCaption`n"
        $path = New-TestFile 'metadata/header-metadata.vtt' $content
        Assert-Result (Invoke-Normalizer $path '3' '1') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        Assert-True $document.Normalized.StartsWith("WEBVTT Generated`nKind: captions`nLanguage: en`n`n") 'Header metadata changed or moved'
    }

    Invoke-Test 'BOM input rewrites without BOM' {
        $path = New-TestFile 'encoding/bom-rewrite.vtt' "WEBVTT`n" -Bom
        Assert-Result (Invoke-Normalizer $path '1' '1') 0 'RESULT=0' $null
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        Assert-False $hasBom 'Rewritten output retained UTF-8 BOM'
    }

    Invoke-Test 'BOM no-change input preserves original bytes' {
        $content = "WEBVTT`r`n`r`n00:00:00.000 --> 00:00:01.000`r`nCaption`r`n"
        Assert-UnchangedSuccess 'encoding/bom-no-change.vtt' $content '1' -Bom
    }

    Invoke-Test 'CRLF rewrite produces deterministic LF' {
        $content = "WEBVTT`r`n`r`n00:00:01.000 --> 00:00:02.000`r`nCaption`r`n"
        $path = New-TestFile 'encoding/crlf.vtt' $content
        Assert-Result (Invoke-Normalizer $path '3' '1') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        Assert-False $document.Content.Contains("`r") 'Rewritten file contains CR characters'
    }

    Invoke-Test 'file without trailing newline normalizes successfully' {
        $path = New-TestFile 'encoding/no-trailing-newline.vtt' 'WEBVTT'
        Assert-Result (Invoke-Normalizer $path '1.234' '1') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        Assert-True $document.Content.EndsWith("`n") 'Rewritten file does not end with one newline'
        Assert-Equal 1234L ([int64]$document.Cues[-1].End) 'No-newline input ended at wrong duration'
    }

    Invoke-Test 'rewritten output ends with exactly one newline' {
        $path = New-TestFile 'encoding/final-newline.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '2' '1') 0 'RESULT=0' $null
        $bytes = [System.IO.File]::ReadAllBytes($path)
        Assert-True ($bytes.Length -gt 0 -and $bytes[-1] -eq 10) 'Rewritten output has no final LF byte'
        Assert-False ($bytes.Length -gt 1 -and $bytes[-2] -eq 10) 'Rewritten output has more than one final LF byte'
    }

    Invoke-Test 'missing file returns actual one-line error' {
        $path = Join-Path $tempRoot 'validation/missing.vtt'
        Assert-Result (Invoke-Normalizer $path '1' '1') 1 $null 'VTT file does not exist:'
    }

    Invoke-Test 'invalid header leaves file unchanged' {
        $path = New-TestFile 'validation/header.vtt' " WEBVTT`n"
        $null = Assert-FailureLeavesFileUntouched $path '1' '1' 'Invalid WEBVTT header'
    }

    Invoke-Test 'WEBVTT signature suffix without whitespace fails' {
        $path = New-TestFile 'validation/header-suffix.vtt' "WEBVTTINVALID`n"
        $null = Assert-FailureLeavesFileUntouched $path '1' '1' 'Invalid WEBVTT header'
    }

    Invoke-Test 'whitespace VTT path fails through RESULT contract' {
        Assert-Result (Invoke-Normalizer '   ' '1' '1') 1 $null 'VttPath must not be empty'
    }

    Invoke-Test 'directory path is rejected as not a regular file' {
        $directory = Join-Path $tempRoot 'validation/directory'
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
        Assert-Result (Invoke-Normalizer $directory '1' '1') 1 $null 'VTT path is not a regular file:'
    }

    foreach ($case in @(
        @{ Name = 'zero video duration fails'; Value = '0'; Message = 'DurationSeconds must be greater than zero' },
        @{ Name = 'negative video duration fails'; Value = '-1'; Message = 'DurationSeconds must be greater than zero' },
        @{ Name = 'invalid video duration fails'; Value = 'abc'; Message = 'DurationSeconds must be a valid invariant-culture number' },
        @{ Name = 'NaN video duration fails'; Value = 'NaN'; Message = 'DurationSeconds must be a finite number' },
        @{ Name = 'infinite video duration fails'; Value = 'Infinity'; Message = 'DurationSeconds must be a finite number' }
    )) {
        Invoke-Test $case.Name {
            $path = New-TestFile ('validation/' + $case.Name + '.vtt') "WEBVTT`n"
            $null = Assert-FailureLeavesFileUntouched $path $case.Value '1' $case.Message
        }
    }

    foreach ($case in @(
        @{ Name = 'zero cue interval fails'; Value = '0'; Message = 'CueIntervalSeconds must be greater than zero' },
        @{ Name = 'negative cue interval fails'; Value = '-1'; Message = 'CueIntervalSeconds must be greater than zero' },
        @{ Name = 'invalid cue interval fails'; Value = 'abc'; Message = 'CueIntervalSeconds must be a valid invariant-culture number' },
        @{ Name = 'NaN cue interval fails'; Value = 'NaN'; Message = 'CueIntervalSeconds must be a finite number' },
        @{ Name = 'infinite cue interval fails'; Value = '-Infinity'; Message = 'CueIntervalSeconds must be a finite number' }
    )) {
        Invoke-Test $case.Name {
            $path = New-TestFile ('validation/' + $case.Name + '.vtt') "WEBVTT`n"
            $null = Assert-FailureLeavesFileUntouched $path '1' $case.Value $case.Message
        }
    }

    Invoke-Test 'duration milliseconds round midpoint away from zero' {
        $pathLow = New-TestFile 'rounding/duration-low.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $pathLow '1.2344' '2') 0 'RESULT=0' $null
        Assert-Equal 1234L ([int64](Get-TestDocument $pathLow).Cues[-1].End) '1.2344 did not round to 1234 ms'
        $pathHigh = New-TestFile 'rounding/duration-high.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $pathHigh '1.2345' '2') 0 'RESULT=0' $null
        Assert-Equal 1235L ([int64](Get-TestDocument $pathHigh).Cues[-1].End) '1.2345 did not round to 1235 ms'
    }

    Invoke-Test 'duration rounding to zero fails' {
        $path = New-TestFile 'rounding/duration-zero.vtt' "WEBVTT`n"
        $null = Assert-FailureLeavesFileUntouched $path '0.0004' '1' 'DurationSeconds rounds to zero milliseconds'
    }

    Invoke-Test 'interval rounding to zero fails' {
        $path = New-TestFile 'rounding/interval-zero.vtt' "WEBVTT`n"
        $null = Assert-FailureLeavesFileUntouched $path '1' '0.0004' 'CueIntervalSeconds rounds to zero milliseconds'
    }

    Invoke-Test 'half-millisecond interval rounds to one millisecond' {
        $path = New-TestFile 'rounding/interval-one.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '0.003' '0.0005') 0 'RESULT=0' $null
        Assert-CueRanges (Get-TestDocument $path).Cues @(@(0L, 1L), @(1L, 2L), @(2L, 3L))
    }

    Invoke-Test 'duration beyond supported millisecond range fails' {
        $path = New-TestFile 'rounding/duration-range.vtt' "WEBVTT`n"
        $null = Assert-FailureLeavesFileUntouched $path '315360001' '1' 'DurationSeconds exceeds the supported millisecond range'
    }

    Invoke-Test 'interval beyond supported millisecond range fails' {
        $path = New-TestFile 'rounding/interval-range.vtt' "WEBVTT`n"
        $null = Assert-FailureLeavesFileUntouched $path '1' '315360001' 'CueIntervalSeconds exceeds the supported millisecond range'
    }

    Invoke-Test 'invariant culture accepts period decimals' {
        $path = New-TestFile 'culture/period.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '31.5' '6.5' 'fr-FR') 0 'RESULT=0' $null
        Assert-Equal 31500L ([int64](Get-TestDocument $path).Cues[-1].End) 'Invariant decimal parsed incorrectly'
    }

    Invoke-Test 'invariant culture rejects comma decimals' {
        $path = New-TestFile 'culture/comma.vtt' "WEBVTT`n"
        $null = Assert-FailureLeavesFileUntouched $path '31,5' '6' 'DurationSeconds must be a valid invariant-culture number'
    }

    Invoke-Test 'path containing spaces works' {
        $path = New-TestFile 'path with spaces/file with spaces.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '1.5' '1') 0 'RESULT=0' $null
        Assert-Equal 1500L ([int64](Get-TestDocument $path).Cues[-1].End) 'Space path ended incorrectly'
    }

    Invoke-Test 'Unicode path works' {
        $path = New-TestFile 'vidéo 字/captïons 日.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '1.5' '1') 0 'RESULT=0' $null
        Assert-Equal 1500L ([int64](Get-TestDocument $path).Cues[-1].End) 'Unicode path ended incorrectly'
    }

    Invoke-Test 'long duration hours do not wrap' {
        $path = New-TestFile 'formatting/long.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '90000.417' '90000') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        Assert-Contains $document.Content '25:00:00.417' 'Hours wrapped after 24'
    }

    Invoke-Test 'timeline union covers exact duration with overlaps' {
        $content = "WEBVTT`n`n00:00:01.000 --> 00:00:05.000`nA`n`n00:00:03.000 --> 00:00:08.000`nB`n`n00:00:10.000 --> 00:00:11.000`nC`n"
        $path = New-TestFile 'invariants/union.vtt' $content
        Assert-Result (Invoke-Normalizer $path '12.417' '2.5') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        Assert-TimelineUnion $document.Cues 12417L
        foreach ($cue in @($document.Cues | Where-Object { $_.Generated })) {
            Assert-GeneratedCue $cue 2500L 12417L
        }
    }

    Invoke-Test 'success and failure each emit one RESULT line' {
        $successPath = New-TestFile 'output/success.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $successPath '1' '1') 0 'RESULT=0' $null
        $failurePath = New-TestFile 'output/failure.vtt' "invalid`n"
        Assert-Result (Invoke-Normalizer $failurePath '1' '1') 1 $null 'Invalid WEBVTT header'
    }

    Invoke-Test 'successful replacement leaves no temporary files' {
        $path = New-TestFile 'cleanup/success.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '1' '1') 0 'RESULT=0' $null
        Assert-NoTemporaryFiles $path
    }

    Invoke-Test 'unknown block reports line and leaves file untouched' {
        $content = "WEBVTT`n`nNOTE accepted`n`nX-TIMESTAMP-MAP=LOCAL:00:00:00.000`nvalue`n"
        $path = New-TestFile 'strict/unknown.vtt' $content
        $result = Assert-FailureLeavesFileUntouched $path '5' '1' 'Unrecognized WebVTT block beginning at line 5:'
        Assert-Equal 1 $result.Lines.Count 'Unknown block failure emitted multiple lines'
    }

    Invoke-Test 'whitespace-only unknown block has visible excerpt' {
        $content = "WEBVTT`n`n   `n`n"
        $path = New-TestFile 'strict/unknown-whitespace.vtt' $content
        $null = Assert-FailureLeavesFileUntouched $path '5' '1' 'Unrecognized WebVTT block beginning at line 3: <whitespace-only>'
    }

    Invoke-Test 'malformed timing block fails before replacement' {
        $content = "WEBVTT`n`n00:61.000 --> 00:62.000`nCaption`n"
        $path = New-TestFile 'strict/malformed-timing.vtt' $content
        $null = Assert-FailureLeavesFileUntouched $path '5' '1' 'Invalid WebVTT cue timing at line 3'
    }

    Invoke-Test 'cue-like content without header separator fails safely' {
        $content = "WEBVTT`n00:00:00.000 --> 00:00:01.000`nOriginal caption`n"
        $path = New-TestFile 'strict/missing-header-separator.vtt' $content
        $null = Assert-FailureLeavesFileUntouched $path '2' '1' 'Missing blank line before WebVTT cue-like content at line 2'
    }

    Invoke-Test 'nonpositive existing cue duration fails' {
        $content = "WEBVTT`n`n00:00:05.000 --> 00:00:05.000`nCaption`n"
        $path = New-TestFile 'strict/nonpositive.vtt' $content
        $null = Assert-FailureLeavesFileUntouched $path '10' '1' 'WebVTT cue end must be greater than start at line 3'
    }

    Invoke-Test 'existing cue timestamp beyond supported range fails' {
        $content = "WEBVTT`n`n87601:00:00.000 --> 87601:00:01.000`nCaption`n"
        $path = New-TestFile 'strict/timestamp-range.vtt' $content
        $null = Assert-FailureLeavesFileUntouched $path '10' '1' 'WebVTT timestamp exceeds the supported range at line 3'
    }

    Invoke-Test 'out-of-order cue identifies first offending line' {
        $content = "WEBVTT`n`n00:00:05.000 --> 00:00:08.000`nCaption A`n`nsecond-id`n00:00:02.000 --> 00:00:10.000`nCaption B`n"
        $path = New-TestFile 'strict/out-of-order.vtt' $content
        $result = Assert-FailureLeavesFileUntouched $path '12' '1' 'Out-of-order WebVTT cue at line 6: start 00:00:02.000 is earlier than previous cue start 00:00:05.000'
        Assert-Equal 1 $result.Lines.Count 'Out-of-order failure emitted multiple lines'
    }

    Invoke-Test 'equal cue starts succeed and preserve source order' {
        $content = "WEBVTT`n`nFirst`n00:00:02.000 --> 00:00:05.000`nFirst payload`n`nSecond`n00:00:02.000 --> 00:00:04.000`nSecond payload`n"
        $path = New-TestFile 'ordering/equal.vtt' $content
        Assert-Result (Invoke-Normalizer $path '6' '1') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        $existing = @($document.Cues | Where-Object { -not $_.Generated })
        Assert-Equal 'First' $existing[0].Identifier 'First equal-start cue moved'
        Assert-Equal 'Second' $existing[1].Identifier 'Second equal-start cue moved'
    }

    Invoke-Test 'nondecreasing overlapping cue starts succeed' {
        $content = "WEBVTT`n`n00:00:02.000 --> 00:00:10.000`nCaption A`n`n00:00:05.000 --> 00:00:08.000`nCaption B`n"
        $path = New-TestFile 'ordering/nondecreasing-overlap.vtt' $content
        Assert-Result (Invoke-Normalizer $path '12' '2') 0 'RESULT=0' $null
        $document = Get-TestDocument $path
        Assert-Equal 'Caption A' ([string]$document.Cues[1].Payload[0]) 'First overlapping cue changed'
        Assert-Equal 'Caption B' ([string]$document.Cues[2].Payload[0]) 'Second overlapping cue changed'
        Assert-TimelineUnion $document.Cues 12000L
    }

    Invoke-Test 'STYLE after cue content fails safely' {
        $content = "WEBVTT`n`n00:00:00.000 --> 00:00:01.000`nCaption`n`nSTYLE`n::cue { color: red; }`n"
        $path = New-TestFile 'strict/style-after-cue.vtt' $content
        $null = Assert-FailureLeavesFileUntouched $path '2' '1' 'STYLE block at line 6 appears after cue content'
    }

    Invoke-Test 'REGION after cue content fails safely' {
        $content = "WEBVTT`n`n00:00:00.000 --> 00:00:01.000`nCaption`n`nREGION`nid:late`n"
        $path = New-TestFile 'strict/region-after-cue.vtt' $content
        $null = Assert-FailureLeavesFileUntouched $path '2' '1' 'REGION block at line 6 appears after cue content'
    }

    Invoke-Test 'parser validates all cues before clipping' {
        $content = "WEBVTT`n`n00:00:00.000 --> 00:00:02.000`nValid`n`n00:00:20.000 --> 00:00:19.000`nInvalid outside duration`n"
        $path = New-TestFile 'strict/validate-before-clipping.vtt' $content
        $null = Assert-FailureLeavesFileUntouched $path '10' '1' 'WebVTT cue end must be greater than start at line 6'
    }

    Invoke-Test 'Windows replacement passes a true null backup path' {
        $scriptContent = [System.IO.File]::ReadAllText($productionScript)
        Assert-False ([regex]::IsMatch($scriptContent, '(?s)File\]::Replace\([^\)]*\$null\)')) 'Windows File.Replace receives $null backup path'
        Assert-True ([regex]::IsMatch($scriptContent, '(?s)File\]::Replace\(\s*\$temporaryPath,\s*\$TargetPath,\s*\[System\.Management\.Automation\.Language\.NullString\]::Value\s*\)')) 'Windows File.Replace does not receive NullString.Value'
        Assert-False $scriptContent.Contains('$backupPath') 'Windows replacement still creates a cleanup-sensitive backup'
    }

    Invoke-Test 'coverage cue limit is checked before cue allocation' {
        $scriptContent = [System.IO.File]::ReadAllText($productionScript)
        $preflightIndex = $scriptContent.IndexOf('Assert-CoverageCueLimit')
        $allocationIndex = $scriptContent.IndexOf('$generated = New-Object System.Collections.ArrayList')
        Assert-True ($preflightIndex -ge 0) 'Coverage cue preflight function is missing'
        Assert-True ($allocationIndex -ge 0) 'Coverage allocation marker is missing'
        Assert-True ($preflightIndex -lt $allocationIndex) 'Coverage cue limit is checked after allocation starts'
    }

    Invoke-Test 'coverage cue limit fails safely without bulk allocation' {
        $content = "WEBVTT`n"
        $path = New-TestFile 'strict/coverage-limit.vtt' $content
        $null = Assert-FailureLeavesFileUntouched $path '1000.001' '0.001' 'Requested timeline would generate more than 1000000 coverage cues'
    }

    Invoke-Test 'timeline calculations use integer division after conversion' {
        $scriptContent = [System.IO.File]::ReadAllText($productionScript)
        Assert-False $scriptContent.Contains('[Math]::Floor') 'Timeline calculation still uses floating-point floor division'
        Assert-False $scriptContent.Contains('$intervalLength / [double]') 'Coverage preflight still uses floating-point division'
    }

    Invoke-Test 'test harness launches the current PowerShell engine' {
        $testContent = [System.IO.File]::ReadAllText($PSCommandPath)
        $hardcodedEnginePattern = '(?m)&\s+' + 'pwsh\b'
        Assert-False ([regex]::IsMatch($testContent, $hardcodedEnginePattern)) 'Harness hardcodes pwsh child invocations'
        Assert-Contains $testContent '$script:PowerShellExecutable' 'Harness does not record the current PowerShell executable'
    }

    Invoke-Test 'batch wrapper preserves quoting output and exit code contract' {
        Assert-True ([System.IO.File]::Exists($batchScript)) 'Normalize-WebVtt.bat is missing'
        $batch = [System.IO.File]::ReadAllText($batchScript)
        Assert-True ([regex]::IsMatch($batch, '(?im)^@echo off\s*$')) 'Batch must start with @echo off'
        Assert-Contains $batch '%~dp0Normalize-WebVtt.ps1' 'Batch does not locate script with %~dp0'
        foreach ($argument in @('%~1', '%~2', '%~3')) {
            Assert-Contains $batch $argument "Batch is missing $argument"
        }
        Assert-True ([regex]::IsMatch($batch, '(?im)^exit /b %SCRIPT_EXIT_CODE%\s*$')) 'Batch does not return saved exit code'
        Assert-False ([regex]::IsMatch($batch, '(?i)FOR\s*/F')) 'Batch uses forbidden FOR /F'
        Assert-False ([regex]::IsMatch($batch, '(?i)EnableDelayedExpansion')) 'Batch enables delayed expansion'
        $echoLines = @($batch -split '\r?\n' | Where-Object { $_ -match '(?i)^\s*@?echo\b' })
        Assert-Equal 1 $echoLines.Count 'Batch contains extra echo statements'
    }

    Invoke-Test 'core processing uses no Unix command-line utilities' {
        $scriptContent = [System.IO.File]::ReadAllText($productionScript)
        $testContent = [System.IO.File]::ReadAllText($PSCommandPath)
        foreach ($command in @('chmod', 'mv', 'cp', 'rm', 'sed', 'awk', 'grep')) {
            Assert-False ([regex]::IsMatch($scriptContent, "(?im)^\s*&?\s*$command\b")) "Production script invokes forbidden command $command"
            Assert-False ([regex]::IsMatch($testContent, "(?im)^\s*&?\s*$command\b")) "Test harness invokes forbidden command $command"
        }
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

[Console]::WriteLine('')
[Console]::WriteLine("Summary: $($script:Passed) passed, $($script:Failed) failed, $($script:Skipped) skipped")
foreach ($failure in $script:Failures) {
    [Console]::WriteLine("  $failure")
}
if ($script:Failed -gt 0) {
    exit 1
}
exit 0
