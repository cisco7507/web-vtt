[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0
$script:Failures = [System.Collections.Generic.List[string]]::new()
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$productionScript = Join-Path $repoRoot 'Normalize-WebVtt.ps1'
$batchScript = Join-Path $repoRoot 'Normalize-WebVtt.bat'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('webvtt-normalizer-tests-' + [Guid]::NewGuid().ToString('N'))
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$wordJoiner = [char]0x2060

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "$Message (expected '$Expected', actual '$Actual')"
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
    param([string]$RelativePath, [string]$Content, [switch]$Bom)
    $path = Join-Path $tempRoot $RelativePath
    $directory = Split-Path -Parent $path
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $encoding = if ($Bom) { [System.Text.UTF8Encoding]::new($true) } else { $utf8NoBom }
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
        $stdout = @(& pwsh -NoLogo -NoProfile -NonInteractive -File $productionScript -VttPath $Path -DurationSeconds $Duration -CueIntervalSeconds $Interval 2> $stderrPath)
    }
    else {
        $command = @(
            "[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($(ConvertTo-SingleQuotedLiteral $Culture))"
            "& $(ConvertTo-SingleQuotedLiteral $productionScript) -VttPath $(ConvertTo-SingleQuotedLiteral $Path) -DurationSeconds $(ConvertTo-SingleQuotedLiteral $Duration) -CueIntervalSeconds $(ConvertTo-SingleQuotedLiteral $Interval)"
            'exit $LASTEXITCODE'
        ) -join '; '
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $stdout = @(& pwsh -NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded 2> $stderrPath)
    }
    $exitCode = $LASTEXITCODE
    $stderr = if (Test-Path -LiteralPath $stderrPath) { [System.IO.File]::ReadAllText($stderrPath) } else { '' }
    Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ ExitCode = $exitCode; Lines = $stdout; StdErr = $stderr }
}

function Assert-Result {
    param($Result, [int]$ExitCode, [string]$ExactLine, [string]$Contains)
    Assert-Equal $ExitCode $Result.ExitCode 'Unexpected process exit code'
    Assert-Equal 1 $Result.Lines.Count 'Standard output must contain exactly one line'
    if (-not [string]::IsNullOrEmpty($ExactLine)) {
        Assert-Equal $ExactLine ([string]$Result.Lines[0]) 'Unexpected RESULT line'
    }
    if (-not [string]::IsNullOrEmpty($Contains)) {
        Assert-True ([string]$Result.Lines[0]).Contains($Contains) "RESULT line must contain '$Contains'"
    }
}

function Get-GeneratedCue {
    param([string]$Content)
    $pattern = '(?m)^(?<id>\d+)\n(?<start>\d{2,}:\d{2}:\d{2}\.000) --> (?<end>\d{2,}:\d{2}:\d{2}\.000)\n(?<payload>.)$'
    return ,@([regex]::Matches($Content, $pattern))
}

function Convert-TimestampToSeconds {
    param([string]$Timestamp)
    $parts = $Timestamp.Substring(0, $Timestamp.Length - 4).Split(':')
    return ([int64]$parts[0] * 3600L) + ([int64]$parts[1] * 60L) + [int64]$parts[2]
}

function Assert-GeneratedTimeline {
    param([string]$Path, [int64]$Duration, [int64]$Interval, [int]$ExpectedCount)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'Generated file must not have a BOM'
    $content = $utf8NoBom.GetString($bytes)
    Assert-True $content.StartsWith("WEBVTT`n`n") 'Generated file must start with WEBVTT and one blank line'
    Assert-True $content.EndsWith("`n") 'Generated file must end with one newline'
    Assert-True (-not $content.Contains("`r")) 'Generated file must use LF line endings'
    $cues = Get-GeneratedCue $content
    Assert-Equal $ExpectedCount $cues.Count 'Unexpected cue count'
    $previousEnd = 0L
    for ($index = 0; $index -lt $cues.Count; $index++) {
        $cue = $cues[$index]
        $start = Convert-TimestampToSeconds $cue.Groups['start'].Value
        $end = Convert-TimestampToSeconds $cue.Groups['end'].Value
        Assert-Equal ($index + 1) ([int]$cue.Groups['id'].Value) 'Cue identifiers must be sequential'
        Assert-Equal $previousEnd $start 'Cue timeline contains a gap or overlap'
        Assert-True ($start -lt $end) 'Cue start must precede cue end'
        Assert-True (($end - $start) -le $Interval) 'Cue exceeds rounded interval'
        Assert-Equal ([string]$wordJoiner) $cue.Groups['payload'].Value 'Cue payload must be one WORD JOINER'
        $previousEnd = $end
    }
    Assert-Equal $Duration $previousEnd 'Final cue must end at rounded video duration'
}

function Assert-Unchanged {
    param([string]$Content)
    $path = New-TestFile ('unchanged-' + [Guid]::NewGuid().ToString('N') + '.vtt') $Content
    $beforeBytes = [System.IO.File]::ReadAllBytes($path)
    $fixedTime = [DateTime]::UtcNow.AddMinutes(-10)
    [System.IO.File]::SetLastWriteTimeUtc($path, $fixedTime)
    $beforeTime = [System.IO.File]::GetLastWriteTimeUtc($path)
    $result = Invoke-Normalizer $path
    Assert-Result $result 0 'RESULT=0'
    $afterBytes = [System.IO.File]::ReadAllBytes($path)
    Assert-True ([System.Linq.Enumerable]::SequenceEqual[byte]($beforeBytes, $afterBytes)) 'Existing cue file bytes changed'
    Assert-Equal $beforeTime ([System.IO.File]::GetLastWriteTimeUtc($path)) 'Existing cue file timestamp changed'
}

[System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
try {
    Invoke-Test 'production script exists' { Assert-True (Test-Path -LiteralPath $productionScript -PathType Leaf) 'Normalize-WebVtt.ps1 is missing' }
    Invoke-Test 'header-only file generates three cues' {
        $path = New-TestFile 'header-only.vtt' "WEBVTT`n"
        $result = Invoke-Normalizer $path '13.2' '6'
        Assert-Result $result 0 'RESULT=0'
        Assert-GeneratedTimeline $path 14 6 3
    }
    Invoke-Test 'exact duration and interval generate three cues' {
        $path = New-TestFile 'exact.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '18' '6') 0 'RESULT=0'
        Assert-GeneratedTimeline $path 18 6 3
    }
    Invoke-Test 'fractional duration rounds upward' {
        $path = New-TestFile 'fractional-duration.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '61.01' '6') 0 'RESULT=0'
        Assert-GeneratedTimeline $path 62 6 11
        Assert-True ([System.IO.File]::ReadAllText($path).Contains('00:01:02.000')) 'Expected rounded final timestamp'
    }
    Invoke-Test 'fractional cue interval rounds upward' {
        $path = New-TestFile 'fractional-interval.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '20' '6.01') 0 'RESULT=0'
        Assert-GeneratedTimeline $path 20 7 3
    }
    Invoke-Test 'cue interval longer than video generates one cue' {
        $path = New-TestFile 'long-interval.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '5.2' '30') 0 'RESULT=0'
        Assert-GeneratedTimeline $path 6 30 1
    }
    Invoke-Test 'existing long-form timed cue is untouched' { Assert-Unchanged "WEBVTT`n`n1`n00:00:01.000 --> 00:00:04.000`nCaption`n" }
    Invoke-Test 'existing cue with settings is untouched' { Assert-Unchanged "WEBVTT`n`n00:00:01.000 --> 00:00:04.000 align:start line:90%`nCaption`n" }
    Invoke-Test 'existing short-form timed cue is untouched' { Assert-Unchanged "WEBVTT`n`n00:01.000 --> 00:04.000`nCaption`n" }
    Invoke-Test 'NOTE-only file is replaced' {
        $path = New-TestFile 'note-only.vtt' "WEBVTT`n`nNOTE No captions were supplied.`n"
        Assert-Result (Invoke-Normalizer $path) 0 'RESULT=0'
        Assert-GeneratedTimeline $path 14 6 3
    }
    Invoke-Test 'STYLE-only file is replaced' {
        $path = New-TestFile 'style-only.vtt' "WEBVTT`n`nSTYLE`n::cue {`n color: white;`n}`n"
        Assert-Result (Invoke-Normalizer $path) 0 'RESULT=0'
        Assert-GeneratedTimeline $path 14 6 3
    }
    Invoke-Test 'REGION-only file is replaced' {
        $path = New-TestFile 'region-only.vtt' "WEBVTT`n`nREGION`nid:region1`nwidth:40%`n"
        Assert-Result (Invoke-Normalizer $path) 0 'RESULT=0'
        Assert-GeneratedTimeline $path 14 6 3
    }
    Invoke-Test 'text containing arrow is not a cue' {
        $path = New-TestFile 'arrow-text.vtt' "WEBVTT`n`nNOTE this --> that`n`nidentifier`npayload --> text`n"
        Assert-Result (Invoke-Normalizer $path) 0 'RESULT=0'
        Assert-GeneratedTimeline $path 14 6 3
    }
    Invoke-Test 'missing file reports actual error' {
        $path = Join-Path $tempRoot 'does-not-exist.vtt'
        $result = Invoke-Normalizer $path
        Assert-Result $result 1 $null 'VTT file does not exist:'
        Assert-True ([string]$result.Lines[0]).StartsWith('RESULT=') 'Failure must use RESULT contract'
    }
    Invoke-Test 'whitespace VTT path fails through RESULT contract' {
        Assert-Result (Invoke-Normalizer '   ') 1 $null 'VttPath must not be empty'
    }
    Invoke-Test 'directory path is rejected as not a regular file' {
        $directory = Join-Path $tempRoot 'not-a-file'
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
        Assert-Result (Invoke-Normalizer $directory) 1 $null 'VTT path is not a regular file:'
    }
    Invoke-Test 'invalid header fails' {
        $path = New-TestFile 'invalid-header.vtt' " WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path) 1 $null 'Invalid WEBVTT header'
    }
    foreach ($case in @(
        @{ Name = 'zero video duration'; Duration = '0'; Message = 'DurationSeconds must be greater than zero' },
        @{ Name = 'negative video duration'; Duration = '-1'; Message = 'DurationSeconds must be greater than zero' },
        @{ Name = 'invalid video duration'; Duration = 'abc'; Message = 'DurationSeconds must be a valid invariant-culture number' },
        @{ Name = 'NaN video duration'; Duration = 'NaN'; Message = 'DurationSeconds must be a finite number' },
        @{ Name = 'infinite video duration'; Duration = 'Infinity'; Message = 'DurationSeconds must be a finite number' }
    )) {
        Invoke-Test $case.Name {
            $path = New-TestFile ($case.Name + '.vtt') "WEBVTT`n"
            Assert-Result (Invoke-Normalizer $path $case.Duration '6') 1 $null $case.Message
        }
    }
    Invoke-Test 'duration beyond safe range is rejected' {
        $path = New-TestFile 'duration-too-large.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '315360001' '6') 1 $null 'DurationSeconds exceeds the supported maximum'
    }
    Invoke-Test 'cue interval beyond safe range is rejected' {
        $path = New-TestFile 'interval-too-large.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '20' '315360001') 1 $null 'CueIntervalSeconds exceeds the supported maximum'
    }
    foreach ($case in @(
        @{ Name = 'zero cue interval'; Interval = '0'; Message = 'CueIntervalSeconds must be greater than zero' },
        @{ Name = 'negative cue interval'; Interval = '-1'; Message = 'CueIntervalSeconds must be greater than zero' },
        @{ Name = 'invalid cue interval'; Interval = 'abc'; Message = 'CueIntervalSeconds must be a valid invariant-culture number' },
        @{ Name = 'NaN cue interval'; Interval = 'NaN'; Message = 'CueIntervalSeconds must be a finite number' },
        @{ Name = 'infinite cue interval'; Interval = '-Infinity'; Message = 'CueIntervalSeconds must be a finite number' }
    )) {
        Invoke-Test $case.Name {
            $path = New-TestFile ($case.Name + '.vtt') "WEBVTT`n"
            Assert-Result (Invoke-Normalizer $path '20' $case.Interval) 1 $null $case.Message
        }
    }
    Invoke-Test 'invariant culture accepts period decimal' {
        $path = New-TestFile 'culture-period.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '61.5' '6.5' 'fr-FR') 0 'RESULT=0'
        Assert-GeneratedTimeline $path 62 7 9
    }
    Invoke-Test 'invariant culture rejects comma decimal' {
        $path = New-TestFile 'culture-comma.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '61,5' '6' 'fr-FR') 1 $null 'DurationSeconds must be a valid invariant-culture number'
    }
    Invoke-Test 'path containing spaces works' {
        $path = New-TestFile 'directory with spaces/file with spaces.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path) 0 'RESULT=0'
        Assert-GeneratedTimeline $path 14 6 3
    }
    Invoke-Test 'Unicode path works' {
        $path = New-TestFile 'vidéo 字/captïons 日.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path) 0 'RESULT=0'
        Assert-GeneratedTimeline $path 14 6 3
    }
    Invoke-Test 'UTF-8 BOM input produces BOM-free output' {
        $path = New-TestFile 'bom.vtt' "WEBVTT`n" -Bom
        Assert-Result (Invoke-Normalizer $path) 0 'RESULT=0'
        Assert-GeneratedTimeline $path 14 6 3
    }
    Invoke-Test 'CRLF cue detection preserves file' { Assert-Unchanged "WEBVTT`r`n`r`n00:00:01.000 --> 00:00:04.000`r`nCaption`r`n" }
    Invoke-Test 'header without trailing newline generates cues' {
        $path = New-TestFile 'no-newline.vtt' 'WEBVTT'
        Assert-Result (Invoke-Normalizer $path) 0 'RESULT=0'
        Assert-GeneratedTimeline $path 14 6 3
    }
    Invoke-Test 'duration over 24 hours does not wrap' {
        $path = New-TestFile 'long-duration.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path '90001' '90000') 0 'RESULT=0'
        Assert-GeneratedTimeline $path 90001 90000 2
        Assert-True ([System.IO.File]::ReadAllText($path).Contains('25:00:01.000')) 'Hours wrapped after 24'
    }
    Invoke-Test 'header text after signature is accepted' {
        $path = New-TestFile 'header-text.vtt' "WEBVTT Generated upstream`n"
        Assert-Result (Invoke-Normalizer $path) 0 'RESULT=0'
    }
    Invoke-Test 'tab after signature is accepted' {
        $path = New-TestFile 'header-tab.vtt' "WEBVTT`tGenerated upstream`n"
        Assert-Result (Invoke-Normalizer $path) 0 'RESULT=0'
    }
    Invoke-Test 'signature suffix without whitespace is rejected' {
        $path = New-TestFile 'header-suffix.vtt' "WEBVTTINVALID`n"
        Assert-Result (Invoke-Normalizer $path) 1 $null 'Invalid WEBVTT header'
    }
    Invoke-Test 'invalid timestamp ranges are not cues' {
        $path = New-TestFile 'invalid-times.vtt' "WEBVTT`n`n00:60.000 --> 00:61.000`ntext`n"
        Assert-Result (Invoke-Normalizer $path) 0 'RESULT=0'
        Assert-GeneratedTimeline $path 14 6 3
    }
    Invoke-Test 'standard output discipline on success and failure' {
        $successPath = New-TestFile 'stdout-success.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $successPath) 0 'RESULT=0'
        $failurePath = New-TestFile 'stdout-failure.vtt' "invalid`n"
        $failure = Invoke-Normalizer $failurePath
        Assert-Result $failure 1 $null 'Invalid WEBVTT header'
        Assert-True ([string]$failure.Lines[0]).StartsWith('RESULT=') 'Failure output must start with RESULT='
    }
    Invoke-Test 'temporary files are absent after successful replacement' {
        $path = New-TestFile 'cleanup/success.vtt' "WEBVTT`n"
        Assert-Result (Invoke-Normalizer $path) 0 'RESULT=0'
        $orphans = @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -Filter '.success.vtt.*.tmp')
        Assert-Equal 0 $orphans.Count 'Temporary file was left after success'
    }
    if ($IsMacOS -or $IsLinux) {
        Invoke-Test 'temporary file is cleaned after replacement failure' {
            $directory = Join-Path $tempRoot 'read-only'
            [System.IO.Directory]::CreateDirectory($directory) | Out-Null
            $path = New-TestFile 'read-only/failure.vtt' "WEBVTT`n"
            & chmod 555 $directory
            try {
                $result = Invoke-Normalizer $path
                Assert-Result $result 1 $null $null
                Assert-True ([string]$result.Lines[0]).StartsWith('RESULT=') 'Failure must use RESULT contract'
                $orphans = @(Get-ChildItem -LiteralPath $directory -Filter '.failure.vtt.*.tmp')
                Assert-Equal 0 $orphans.Count 'Temporary file was left after replacement failure'
            }
            finally {
                & chmod 755 $directory
            }
        }
    }
    else {
        Skip-Test 'temporary file is cleaned after replacement failure' 'Permission simulation is only run by this macOS/Linux harness'
    }
    Invoke-Test 'Windows replacement uses a legal backup path' {
        $scriptContent = [System.IO.File]::ReadAllText($productionScript)
        Assert-True ($scriptContent -notmatch '(?s)File\]::Replace\([^\)]*\$null\)') 'Windows File.Replace must not receive $null as its backup path'
        Assert-True ($scriptContent -match '(?s)File\]::Replace\(\$temporaryPath,\s*\$TargetPath,\s*\$backupPath\)') 'Windows File.Replace must receive a real backup path'
        Assert-True ($scriptContent -match '(?s)File\]::Exists\(\$backupPath\).*File\]::Delete\(\$backupPath\)') 'Windows replacement backup must be cleaned up'
    }
    Invoke-Test 'batch wrapper has required quoting and no output capture' {
        Assert-True (Test-Path -LiteralPath $batchScript -PathType Leaf) 'Normalize-WebVtt.bat is missing'
        $batch = [System.IO.File]::ReadAllText($batchScript)
        Assert-True ($batch -match '(?im)^@echo off\s*$') 'Batch must start with @echo off'
        Assert-True $batch.Contains('%~dp0Normalize-WebVtt.ps1') 'Batch must locate script with %~dp0'
        foreach ($argument in @('%~1', '%~2', '%~3')) { Assert-True $batch.Contains($argument) "Batch is missing $argument" }
        Assert-True ($batch -match '(?im)^exit /b %SCRIPT_EXIT_CODE%\s*$') 'Batch must return the saved PowerShell exit code'
        Assert-True ($batch -notmatch '(?i)FOR\s*/F') 'Batch must not use FOR /F'
        Assert-True ($batch -notmatch '(?i)delayedexpansion') 'Batch must not enable delayed expansion'
        $echoLines = @($batch -split '\r?\n' | Where-Object { $_ -match '(?i)^\s*@?echo\b' })
        Assert-Equal 1 $echoLines.Count 'Batch must contain no extra echo statements'
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

[Console]::WriteLine('')
[Console]::WriteLine("Summary: $($script:Passed) passed, $($script:Failed) failed, $($script:Skipped) skipped")
foreach ($failure in $script:Failures) { [Console]::WriteLine("  $failure") }
if ($script:Failed -gt 0) { exit 1 }
exit 0
