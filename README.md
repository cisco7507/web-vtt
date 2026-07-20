# WebVTT Timeline Normalizer for Telestream Vantage

This dependency-free utility normalizes an existing WebVTT file in place so its
cue coverage begins at zero and ends exactly at the associated video duration.
It preserves existing captions, fills uncovered intervals with invisible cues,
clips captions at the video end, and removes captions that begin outside the
video timeline.

The production execution path is:

```text
Telestream Vantage
    -> Normalize-WebVtt.bat
    -> Windows PowerShell
    -> Normalize-WebVtt.ps1
```

No Python runtime, third-party executable, external PowerShell module, Pester
installation, Unix command-line utility, or other runtime dependency is used.

## Files

- `Normalize-WebVtt.bat` is the Windows and Vantage entry point.
- `Normalize-WebVtt.ps1` parses, validates, normalizes, serializes, and replaces.
- `tests/Test-Normalize-WebVtt.ps1` is the dependency-free macOS test runner.
- `README.md` documents operation and validation.

## Arguments and invocation

The batch file accepts exactly three positional arguments:

1. Path to an existing VTT file.
2. Exact video duration in seconds.
3. Desired generated coverage-cue interval in seconds.

```bat
Normalize-WebVtt.bat "C:\Input Files\captions.vtt" "31.417" "6"
```

The PowerShell script exposes the equivalent named parameters:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File "C:\Vantage Tools\Normalize-WebVtt.ps1" `
  -VttPath "C:\Input Files\captions.vtt" `
  -DurationSeconds "31.417" `
  -CueIntervalSeconds "6"
```

## Exact millisecond conversion

Both numeric arguments enter PowerShell as strings. They are parsed with
`Double.TryParse`, `NumberStyles.Float`, and invariant culture, so a period is
always the decimal separator and thousands separators are not accepted.

Each parsed value is converted once to integer milliseconds:

```powershell
[Math]::Round(
    $seconds * 1000.0,
    0,
    [System.MidpointRounding]::AwayFromZero
)
```

All subsequent timeline calculations use 64-bit integer milliseconds.
Integer quotients and remainders use 64-bit `Math.DivRem`; timeline formatting
and generated-cue preflight do not return to floating-point arithmetic.

| Input seconds | Milliseconds |
| ---: | ---: |
| `31` | `31000` |
| `31.417` | `31417` |
| `31.4174` | `31417` |
| `31.4175` | `31418` |
| `0.250` | `250` |
| `0.0004` | rejected because it rounds to zero |
| `0.0005` | `1` |

The implementation supports values through 315,360,000 seconds
(315,360,000,000 milliseconds) and at most 1,000,000 generated coverage cues.

## Structured parsing and safe failures

The entire document is decoded as strict UTF-8 and parsed in memory before a
temporary output file is created. The parser records the original lines and
starting line number of every block and recognizes:

- the `WEBVTT` signature and header text;
- header metadata lines;
- cues with optional identifiers;
- `MM:SS.mmm` and `HH:MM:SS.mmm` timestamps;
- cue settings and whitespace around `-->`;
- zero, one, or multiple payload lines;
- `NOTE`, `STYLE`, and `REGION` blocks.

All original cues are validated before clipping or removal. Cue duration must be
positive, timestamps must be supported, and cue start times must be
nondecreasing. Equal starts and overlapping intervals are valid; equal-start
cues retain source order.

A cue-like line must follow the blank line that terminates the header. Missing
that separator is a parsing error; the line is never absorbed as header
metadata.

An unknown block fails safely:

```text
RESULT=Unrecognized WebVTT block beginning at line 18: X-TIMESTAMP-MAP=...
```

An out-of-order cue also fails safely:

```text
RESULT=Out-of-order WebVTT cue at line 24: start 00:00:08.000 is earlier than previous cue start 00:00:10.000
```

On any parsing or validation failure, the original bytes remain unchanged and no
temporary or backup file is retained. Error excerpts are sanitized, shortened,
and kept on one line for Vantage. A block containing only WebVTT whitespace is
reported with the visible excerpt `<whitespace-only>`.

`STYLE` and `REGION` blocks are supported only before cue content. Encountering
either after a cue is an error rather than silently relocating it. Their keyword
lines may have trailing spaces or tabs. A block whose first line is `STYLE` or
`REGION` but whose second line is a valid timing line is treated as a cue with
that identifier, not as metadata.

## Existing-caption preservation

Retained cues preserve:

- cue identifiers;
- plain, blank, whitespace-only, Unicode, and multiline payloads;
- inline markup such as `<i>`, `<b>`, `<u>`, `<c>`, and `<v>`;
- settings after the end timestamp;
- source order, including equal-start order;
- the original timing line when clipping is unnecessary.

If clipping is required, only the end timestamp token is replaced. The original
start token, whitespace around the arrow, settings, identifier, and payload
remain unchanged.

For a 31-second video:

```vtt
00:00:25.000 	-->  00:00:35.000 align:center line:10%
Final caption
```

becomes:

```vtt
00:00:25.000 	-->  00:00:31.000 align:center line:10%
Final caption
```

Cues starting at or after the video duration are removed. Earlier cues ending
after the duration are clipped exactly to it.

## Coverage union and gap filling

The normalizer computes the union of all retained existing cue intervals.
Overlapping captions remain untouched and count as continuous coverage wherever
at least one is active. The complement of that union over
`[0, durationMilliseconds)` produces uncovered intervals.

Each uncovered interval is split independently:

```text
step = min(cueIntervalMilliseconds, uncoveredEnd - currentStart)
```

Calculating the remaining interval first avoids overflow. Generated cues cannot
overlap existing coverage, cannot extend beyond their uncovered interval, and
always have positive duration.

For existing captions:

```vtt
00:00:00.000 --> 00:00:04.000
Caption A

00:00:10.000 --> 00:00:15.000
Caption B
```

a six-second interval inserts:

```vtt
00:00:04.000 --> 00:00:10.000
⁠
```

The apparently blank payload line contains one actual U+2060 WORD JOINER.

Overlapping cues from `2–8` and `5–10` form one covered union from `2–10`.
Nothing is inserted between `8–10`.

## Generated cue format

Every generated coverage cue contains:

1. One `HH:MM:SS.mmm --> HH:MM:SS.mmm` timing line.
2. One payload line containing exactly one U+2060 WORD JOINER.
3. No cue identifier.
4. No italics or other markup.

Generated timestamps use at least two hour digits, exactly two minute and second
digits, and exactly three millisecond digits. Hours do not wrap after 24.

For duration `31.417` and interval `6`, a header-only input becomes:

```vtt
WEBVTT

00:00:00.000 --> 00:00:06.000
⁠

00:00:06.000 --> 00:00:12.000
⁠

00:00:12.000 --> 00:00:18.000
⁠

00:00:18.000 --> 00:00:24.000
⁠

00:00:24.000 --> 00:00:30.000
⁠

00:00:30.000 --> 00:00:31.417
⁠
```

For an existing caption followed by generated coverage:

```vtt
WEBVTT

00:00:00.875 --> 00:00:10.000
Existing caption

00:00:10.000 --> 00:00:16.000
⁠

00:00:16.000 --> 00:00:22.000
⁠

00:00:22.000 --> 00:00:28.000
⁠

00:00:28.000 --> 00:00:31.000
⁠
```

## Metadata ordering

Rewritten files use this deterministic order:

1. Original `WEBVTT` header and header metadata.
2. Original `STYLE` and `REGION` blocks in source order.
3. Existing and generated cues positioned from uncovered intervals.
4. Preserved `NOTE` blocks.

A NOTE is anchored before the next existing cue. If that cue is removed, the
NOTE moves before the next retained cue; when none remains, it is retained as a
trailing NOTE. NOTE content is never silently discarded.

Generated blocks are inserted around existing blocks based on uncovered
intervals. Existing blocks are not globally sorted.

## No-change behavior

The original file is not touched when all of the following are true:

- no cue is removed;
- no cue is clipped;
- no coverage cue is generated;
- no metadata relocation is necessary;
- the existing cue union covers the complete video timeline from zero through
  the exact duration.

This preserves original bytes, BOM, CRLF line endings, formatting, and
modification timestamp.

## Rewritten-file and atomic replacement format

When a semantic change is necessary, the complete output is serialized in memory
before file creation. Rewritten output:

- is UTF-8 without BOM;
- uses LF line endings;
- separates blocks with one blank line;
- ends with exactly one newline.

The serializer writes a unique temporary file in the same directory, flushes and
closes it, then replaces the target:

- Windows uses `.NET File.Replace` and passes
  `[System.Management.Automation.Language.NullString]::Value` as the backup
  argument. This is a true null string and avoids the Windows PowerShell 5.1
  binder converting plain `$null` to an illegal empty backup path.
- macOS under PowerShell 7 uses the overwrite form of `.NET File.Move`, keeping
  the rename on the same filesystem.

The implementation creates no backup file. Its temporary path is removed after
success or handled failure. Filesystem-level atomicity ultimately depends on the
local or remote filesystem.

## Vantage result and exit-code contract

The PowerShell process writes exactly one line to standard output.

Success:

```text
RESULT=0
```

Failure:

```text
RESULT=<actual error message>
```

Embedded carriage returns and linefeeds are replaced with spaces. The script
exits `0` on success and `1` on failure. No helper objects, progress messages, or
diagnostics are written to standard output.

The batch wrapper does not inspect or modify `RESULT=`. It passes standard output
through and returns PowerShell's exact exit code.

## Batch quoting behavior

`Normalize-WebVtt.bat` uses `%~dp0` to locate the PowerShell script beside the
batch file. `%~1`, `%~2`, and `%~3` remove one caller-supplied pair of quotes, and
the wrapper reapplies quotes around each argument. This supports ordinary Windows
paths containing spaces.

The wrapper does not use `FOR /F`, delayed expansion, output capture, or extra
`echo` statements.

## macOS testing

Install PowerShell 7 so `pwsh` is on `PATH`, then run from the repository root:

```sh
pwsh -NoProfile -File ./tests/Test-Normalize-WebVtt.ps1
```

The harness creates a unique temporary directory, invokes the production script
as a new child PowerShell process for each case, captures standard output and
standard error separately, validates the exit code, and cleans up in `finally`.
It launches children with the same PowerShell executable that is running the
harness. Thus `powershell.exe` on the Windows server exercises Windows PowerShell
5.1, while `pwsh` on macOS exercises PowerShell 7. It uses no external module,
Pester installation, or Unix command-line utility.

## Test coverage

The harness prints these individual tests:

### Generation and exact milliseconds

- **production script exists** verifies the production entry point is present.
- **header-only file ends at exact fractional duration** generates `0–6`,
  `6–12`, and `12–13.200`.
- **whole-second duration does not add an extra cue** ends exactly at 31 seconds.
- **fractional duration ends at 31.417 seconds** rejects accidental 32-second
  rounding.
- **fractional cue interval uses exact milliseconds** generates 6.5-second steps.
- **subsecond interval generates millisecond cues** generates 250 ms steps.
- **interval longer than video generates one exact cue** produces only `0–5.250`.
- **generated payload is exactly U+2060 without markup or identifiers** checks
  payload and block structure.

### Existing captions, gaps, clipping, and preservation

- **existing shorter cue is preserved and trailing coverage is appended** keeps
  `0–10` and fills through 31.
- **coverage is generated before first cue** fills `0–5`.
- **single internal gap is filled** inserts `4–10`.
- **large internal gap is split by interval** inserts `4–10`, `10–16`, and
  `16–20`.
- **overlapping cues use interval union without false gap** proves `2–8` plus
  `5–10` remains covered through 10.
- **cue extending past video is clipped** changes `25–35` to `25–31`.
- **clipping replaces only end timestamp token** preserves whitespace, settings,
  identifier, and payload.
- **cue beginning at or after video is removed and gap is filled** removes
  outside cues and restores coverage.
- **complete existing coverage leaves bytes and timestamp unchanged** verifies
  narrow no-change behavior.
- **existing identifiers are preserved and generated cues have none** checks both
  identifier policies.
- **existing inline markup and multiline payload are preserved** retains `<i>`
  and `<v>` content.
- **existing cue with zero payload lines is preserved** does not convert it into
  generated content.
- **existing whitespace-only payload line is preserved** retains the exact spaces.
- **short MM SS timestamps are parsed and preserved** accepts `MM:SS.mmm`.

### Metadata and encoding

- **NOTE arrow is preserved and not parsed as cue** protects comment content.
- **STYLE and REGION before cues are preserved** retains valid header-level
  blocks.
- **STYLE and REGION keywords allow trailing WebVTT whitespace** accepts spaces
  and tabs after the metadata keyword.
- **STYLE and REGION cue identifiers are preserved as cues** disambiguates cue
  identifiers from metadata block keywords.
- **NOTE anchored to removed cue moves before next retained cue** verifies NOTE
  retention when anchors disappear.
- **header metadata is preserved before blocks** retains signature metadata.
- **BOM input rewrites without BOM** checks rewritten encoding.
- **BOM no-change input preserves original bytes** checks no-change encoding.
- **CRLF rewrite produces deterministic LF** checks rewritten line endings.
- **file without trailing newline normalizes successfully** accepts EOF after the
  signature.
- **rewritten output ends with exactly one newline** checks final bytes.

### Parameter, numeric, culture, and path validation

- **missing file returns actual one-line error** checks path context.
- **invalid header leaves file unchanged** checks safe failure.
- **WEBVTT signature suffix without whitespace fails** rejects `WEBVTTINVALID`.
- **whitespace VTT path fails through RESULT contract** rejects blank paths.
- **directory path is rejected as not a regular file** distinguishes directories.
- **zero video duration fails** rejects zero.
- **negative video duration fails** rejects negatives.
- **invalid video duration fails** rejects `abc`.
- **NaN video duration fails** rejects NaN.
- **infinite video duration fails** rejects infinity.
- **zero cue interval fails** rejects zero.
- **negative cue interval fails** rejects negatives.
- **invalid cue interval fails** rejects `abc`.
- **NaN cue interval fails** rejects NaN.
- **infinite cue interval fails** rejects infinity.
- **duration milliseconds round midpoint away from zero** verifies `1.2344` and
  `1.2345`.
- **duration rounding to zero fails** rejects `0.0004`.
- **interval rounding to zero fails** rejects `0.0004`.
- **half-millisecond interval rounds to one millisecond** accepts `0.0005`.
- **duration beyond supported millisecond range fails** checks overflow bounds.
- **interval beyond supported millisecond range fails** checks interval bounds.
- **invariant culture accepts period decimals** tests under `fr-FR`.
- **invariant culture rejects comma decimals** rejects `31,5`.
- **path containing spaces works** validates safe argument passing.
- **Unicode path works** validates non-ASCII filesystem paths.

### Timeline, output, and strict parsing

- **long duration hours do not wrap** checks `25:00:00.417`.
- **timeline union covers exact duration with overlaps** programmatically checks
  the union and generated/existing non-overlap.
- **success and failure each emit one RESULT line** validates Vantage output.
- **successful replacement leaves no temporary files** checks cleanup.
- **unknown block reports line and leaves file untouched** checks strict block
  classification, excerpting, bytes, and cleanup.
- **whitespace-only unknown block has visible excerpt** reports
  `<whitespace-only>` instead of an empty diagnostic.
- **malformed timing block fails before replacement** checks invalid timestamp
  syntax.
- **cue-like content without header separator fails safely** prevents a timing
  line from being absorbed into header metadata.
- **nonpositive existing cue duration fails** rejects equal start and end.
- **existing cue timestamp beyond supported range fails** checks timestamp bounds.
- **out-of-order cue identifies first offending line** checks decreasing starts.
- **equal cue starts succeed and preserve source order** checks stable ordering.
- **nondecreasing overlapping cue starts succeed** permits legitimate overlaps.
- **STYLE after cue content fails safely** prevents silent relocation.
- **REGION after cue content fails safely** prevents silent relocation.
- **parser validates all cues before clipping** catches an invalid outside cue
  before removal.
- **Windows replacement passes a true null backup path** guards the PowerShell
  5.1 `File.Replace` binder regression without creating a backup.
- **coverage cue limit is checked before cue allocation** verifies the preflight
  precedes the generated-cue collection.
- **coverage cue limit fails safely without bulk allocation** requests
  1,000,001 one-millisecond cues and confirms an unchanged-file failure.
- **timeline calculations use integer division after conversion** guards exact
  64-bit timestamp formatting and cue-count preflight.
- **test harness launches the current PowerShell engine** prevents macOS-only
  `pwsh` child-process hardcoding.
- **batch wrapper preserves quoting output and exit code contract** statically
  validates the `.bat` file on macOS.
- **core processing uses no Unix command-line utilities** checks both scripts.

## Manual Windows validation

The batch file cannot execute natively on macOS. Test it from `cmd.exe` on the
Vantage Windows host:

```bat
"C:\Vantage Tools\Normalize-WebVtt.bat" "C:\Test Files\captions.vtt" "31.417" "6"
echo %ERRORLEVEL%
```

Expected success output:

```text
RESULT=0
0
```

For a missing file:

```bat
"C:\Vantage Tools\Normalize-WebVtt.bat" "C:\Test Files\missing.vtt" "31.417" "6"
echo %ERRORLEVEL%
```

Expected behavior is one `RESULT=<actual missing-file error>` line followed by
exit code `1`. Also confirm that no `.tmp` or `.bak` file remains beside the VTT.
