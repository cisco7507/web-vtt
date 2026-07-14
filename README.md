# WebVTT Normalizer for Telestream Vantage

This dependency-free utility normalizes an existing WebVTT file in place for a
Telestream Vantage External Process action. If the file already contains a valid
timed cue, it is left byte-for-byte unchanged. If it has a valid `WEBVTT` header
but no timed cues, the utility replaces it with contiguous, invisible cues that
cover the rounded-up video duration.

## Files

- `Normalize-WebVtt.bat` is the Windows and Vantage entry point.
- `Normalize-WebVtt.ps1` validates, parses, generates, and atomically replaces.
- `tests/Test-Normalize-WebVtt.ps1` is the dependency-free macOS test runner.

No Python runtime, third-party executable, PowerShell module, or other runtime
dependency is used.

## Windows and Vantage usage

Configure the Vantage External Process action to run the batch file with exactly
three positional arguments:

```bat
Normalize-WebVtt.bat "C:\Input Files\captions.vtt" "61.37" "6"
```

The batch file finds `Normalize-WebVtt.ps1` relative to its own location and
invokes Windows PowerShell with `-NoLogo`, `-NoProfile`, `-NonInteractive`, and
`-ExecutionPolicy Bypass`. Keep the `.bat` and `.ps1` files in the same directory.

The parameters are:

1. Existing VTT file path.
2. Total video duration in seconds.
3. Desired generated cue interval in seconds.

The PowerShell script can also be invoked directly:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File "C:\Vantage Tools\Normalize-WebVtt.ps1" `
  -VttPath "C:\Input Files\captions.vtt" `
  -DurationSeconds "61.37" `
  -CueIntervalSeconds "6"
```

### Batch quoting behavior

The wrapper uses `%~1`, `%~2`, and `%~3` to remove one pair of surrounding quotes
supplied by the caller, then places each value inside a new pair of quotes. This
preserves paths containing spaces and prevents ordinary batch metacharacters in a
quoted argument from becoming separate commands. Use normal Windows paths and do
not include literal quote characters inside an argument. The wrapper does not
capture, parse, or transform standard output and returns PowerShell's exact exit
code.

## In-place behavior

There is no output-file argument.

- A valid VTT containing at least one timed cue is not written, copied, touched,
  or replaced. Its bytes and modification timestamp remain unchanged.
- A valid VTT without a timed cue is replaced with a clean generated VTT. Existing
  `NOTE`, `STYLE`, and `REGION` metadata is not retained.
- Invalid input is not normalized.

Generated cues have no cue identifier lines. They are contiguous and contain one
U+2060 WORD JOINER as their invisible payload. Output is UTF-8 without a BOM,
uses LF line endings on every platform, and ends with one newline. Timestamps use
`HH:MM:SS.mmm`; hours do not wrap after 24. Existing input cues may still include
identifiers; cue detection supports both forms.

## Result-variable and exit-code contract

The PowerShell process always writes exactly one line to standard output.

Success:

```text
RESULT=0
```

Failure:

```text
RESULT=<actual error message>
```

Embedded carriage returns and linefeeds in error messages are replaced with
spaces. No progress or diagnostic messages are written to standard output.

- Exit code `0`: processing completed successfully.
- Exit code `1`: validation, reading, generation, writing, replacement, or an
  unexpected operation failed.

Vantage should read the single `RESULT=` line from standard output and also use
the process exit code when deciding whether the action succeeded.

## Numeric parsing and rounding

`DurationSeconds` and `CueIntervalSeconds` enter PowerShell as strings and are
parsed explicitly with invariant culture and `NumberStyles.Float`. A period is
the decimal separator; thousands separators are not accepted.

```text
61.37   valid
6.5     valid
61,37   invalid
```

Both values must be finite and greater than zero. Each is independently rounded
up to a whole second with `Math.Ceiling`. The video duration is not rounded to a
multiple of the cue interval. For example, duration `13.2` and interval `6.1`
become 14 seconds and 7 seconds, producing cues from 0–7 and 7–14.

The implementation supports rounded values through 315,360,000 seconds (ten
365-day years) and at most 1,000,000 generated cues. These bounds prevent integer,
memory, and processing-time hazards well beyond realistic media durations.

## Atomic replacement

Generation first writes a uniquely named temporary file in the VTT file's own
directory. The file is flushed and closed before replacement, and cleanup runs
after success or failure.

- On Windows, `.NET File.Replace` atomically replaces the existing target on the
  same volume using a uniquely named backup in the same directory. A real backup
  path is required to avoid Windows PowerShell 5.1 converting a `$null` string
  argument into an illegal empty path. The backup is removed immediately through
  the same guaranteed cleanup path as the temporary file.
- On macOS under PowerShell 7, `.NET File.Move(source, target, true)` performs the
  overwrite rename with both paths on the same filesystem.

These operations prevent a partially written target on normal local filesystems.
Atomicity ultimately depends on the filesystem implementation; remote shares and
special filesystems may provide weaker rename guarantees. If replacement fails,
the original target remains in place and the utility attempts to remove its
temporary and backup files.

## macOS testing

Install PowerShell 7 so that `pwsh` is on `PATH`, then run from the repository
root:

```sh
pwsh -NoProfile -File ./tests/Test-Normalize-WebVtt.ps1
```

The runner creates a unique temporary directory, launches the production script
in a separate `pwsh` process for every behavioral case, validates standard output
and exit codes, and removes test artifacts in a `finally` block. It uses no
Pester installation or external PowerShell module.

## Test coverage

The test runner currently executes 46 tests. Each production-script test starts a
new child `pwsh` process so that parameter handling, standard output, and the
process exit code are exercised in the same way as an external caller. The test
names printed by the runner are shown in bold below.

### Cue generation and rounding

The basic generation example starts with this header-only file:

```vtt
WEBVTT
```

It invokes the script with duration `13.2` and interval `6`. The values round to
14 and 6 seconds, so the expected replacement is:

```vtt
WEBVTT

00:00:00.000 --> 00:00:06.000
⁠

00:00:06.000 --> 00:00:12.000
⁠

00:00:12.000 --> 00:00:14.000
⁠
```

Each apparently blank payload line above contains one actual U+2060 WORD JOINER.

- **production script exists** checks that `Normalize-WebVtt.ps1` is present as a
  regular file before the behavioral cases run.
- **header-only file generates three cues** checks the complete example above,
  including exit code `0`, `RESULT=0`, three contiguous cues, final time
  `00:00:14.000`, UTF-8 without BOM, LF endings, no cue identifiers, and one WORD
  JOINER per cue.
- **exact duration and interval generate three cues** uses duration `18` and
  interval `6` and expects exactly `0–6`, `6–12`, and `12–18`.
- **fractional duration rounds upward** uses duration `61.01` and interval `6`,
  expects a 62-second timeline with 11 cues, and checks that the last cue ends at
  `00:01:02.000`.
- **fractional cue interval rounds upward** uses duration `20` and interval
  `6.01`; the interval becomes 7, producing `0–7`, `7–14`, and `14–20`.
- **cue interval longer than video generates one cue** uses duration `5.2` and
  interval `30`; the duration becomes 6 and one cue covers `0–6` without
  extending to 30 seconds.
- **duration over 24 hours does not wrap** uses duration `90001` and interval
  `90000`, then checks for the final timestamp `25:00:01.000` rather than a
  wrapped one-hour timestamp.

For every generated timeline, the shared assertions also prove that each start
is less than its end, every cue begins at the preceding cue's end, there are no
gaps or overlaps, no cue exceeds the rounded interval, and the last cue ends at
the rounded duration.

### Existing cues and non-cue blocks

These three valid timing forms must make the script return `RESULT=0` without
changing either the file bytes or its modification timestamp:

```vtt
00:00:01.000 --> 00:00:04.000
00:00:01.000 --> 00:00:04.000 align:start line:90%
00:01.000 --> 00:04.000
```

- **existing long-form timed cue is untouched** checks the first timing form,
  including a numeric cue identifier and visible payload.
- **existing cue with settings is untouched** checks that settings after the end
  timestamp do not prevent cue recognition.
- **existing short-form timed cue is untouched** checks the `MM:SS.mmm` form.
- **CRLF cue detection preserves file** uses a timed VTT with Windows CRLF line
  endings and confirms that recognizing it does not normalize or rewrite it.

Metadata and arbitrary arrows are deliberately not treated as cues. For example,
this file has no valid timing line and must be replaced with generated cues:

```vtt
WEBVTT

NOTE this --> that

identifier
payload --> text
```

- **NOTE-only file is replaced** uses `NOTE No captions were supplied.` and
  confirms that a comment is not a timed cue.
- **STYLE-only file is replaced** uses a `STYLE` block containing a `::cue` rule
  and confirms that styling metadata does not suppress generation.
- **REGION-only file is replaced** uses a `REGION` block with `id` and `width`
  settings and confirms that region metadata does not suppress generation.
- **text containing arrow is not a cue** checks the illustrated `NOTE` and payload
  arrows; the literal `-->` is insufficient without valid timestamps.

### Input and numeric validation

Every validation failure must exit with code `1` and emit exactly one
`RESULT=<message>` line. Representative expectations are:

```text
missing.vtt  -> RESULT=VTT file does not exist: ...missing.vtt
duration 0   -> RESULT=DurationSeconds must be greater than zero
duration abc -> RESULT=DurationSeconds must be a valid invariant-culture number...
interval NaN -> RESULT=CueIntervalSeconds must be a finite number
```

- **missing file reports actual error** supplies a nonexistent path and checks
  that the real path appears in the error message.
- **whitespace VTT path fails through RESULT contract** supplies three spaces and
  expects `VttPath must not be empty` rather than parameter-binding noise.
- **directory path is rejected as not a regular file** supplies an existing
  directory and expects a regular-file validation error.
- **invalid header fails** starts the file with ` WEBVTT`; the leading space must
  produce `RESULT=Invalid WEBVTT header`.
- **zero video duration** checks that `0` is rejected.
- **negative video duration** checks that `-1` is rejected.
- **invalid video duration** checks that `abc` is rejected as nonnumeric.
- **NaN video duration** checks that `NaN` is rejected as non-finite.
- **infinite video duration** checks that `Infinity` is rejected as non-finite.
- **duration beyond safe range is rejected** checks that `315360001` exceeds the
  supported 315,360,000-second limit.
- **cue interval beyond safe range is rejected** applies the same upper-bound
  check to an interval of `315360001`.
- **zero cue interval** checks that interval `0` is rejected.
- **negative cue interval** checks that interval `-1` is rejected.
- **invalid cue interval** checks that interval `abc` is rejected as nonnumeric.
- **NaN cue interval** checks that interval `NaN` is rejected as non-finite.
- **infinite cue interval** checks that interval `-Infinity` is rejected as
  non-finite.

### Culture, paths, and encoding

- **invariant culture accepts period decimal** runs the child process under
  `fr-FR` culture with duration `61.5` and interval `6.5`. It expects invariant
  parsing, rounded values 62 and 7, and nine cues.
- **invariant culture rejects comma decimal** uses `61,5` under the same `fr-FR`
  culture and expects a numeric-format failure. The machine culture must not turn
  the comma into a valid decimal separator.
- **path containing spaces works** generates a file at
  `directory with spaces/file with spaces.vtt` and processes it in place.
- **Unicode path works** uses `vidéo 字/captïons 日.vtt` to exercise non-ASCII
  directory and file names.
- **UTF-8 BOM input produces BOM-free output** begins with the byte sequence
  `EF BB BF` before `WEBVTT`, confirms the header is accepted, and checks that the
  generated replacement no longer has a BOM.
- **header without trailing newline generates cues** supplies exactly the six
  characters `WEBVTT` with no line ending and confirms successful generation.

### Header and timing-line parsing

The accepted first-line forms include:

```text
WEBVTT
WEBVTT Generated upstream
WEBVTT<TAB>Generated upstream
```

- **header text after signature is accepted** checks the second form.
- **tab after signature is accepted** checks the third form with an actual tab
  between the signature and descriptive text.
- **signature suffix without whitespace is rejected** uses `WEBVTTINVALID` and
  expects `RESULT=Invalid WEBVTT header`.
- **invalid timestamp ranges are not cues** uses
  `00:60.000 --> 00:61.000`; because valid minutes and seconds are `00–59`, the
  line must not count as a cue and the file is replaced.

### Output, replacement cleanup, and batch wrapper

- **standard output discipline on success and failure** runs one successful case
  and one invalid-header case. Each must emit exactly one line: `RESULT=0` with
  exit code `0`, or `RESULT=Invalid WEBVTT header` with exit code `1`.
- **temporary files are absent after successful replacement** checks the target
  directory for the normal `.filename.<unique-id>.tmp` pattern after success and
  expects no matches.
- **temporary file is cleaned after replacement failure** makes the target
  directory read-only on macOS or Linux, confirms the child reports one failure
  line, restores permissions, and checks that no temporary file remains. The test
  is skipped on platforms where this permission simulation is not used.
- **Windows replacement uses a legal backup path** statically guards the
  Windows PowerShell 5.1 regression: `File.Replace` must receive a real
  same-directory backup path instead of `$null`, and the backup must be deleted
  during cleanup.
- **batch wrapper has required quoting and no output capture** statically checks
  for `@echo off`, `%~dp0Normalize-WebVtt.ps1`, `%~1`, `%~2`, `%~3`, and
  `exit /b %SCRIPT_EXIT_CODE%`. It also rejects `FOR /F`, delayed expansion, and
  any extra `echo` statement that could alter standard output.

## Manual Windows wrapper validation

From `cmd.exe`, create or choose a header-only VTT and run:

```bat
"C:\Vantage Tools\Normalize-WebVtt.bat" "C:\Input Files\captions test.vtt" "13.2" "6"
echo %ERRORLEVEL%
```

The first command must print only:

```text
RESULT=0
```

The following `echo` must print `0`. To validate failure handling, use a missing
input path:

```bat
"C:\Vantage Tools\Normalize-WebVtt.bat" "C:\Input Files\missing file.vtt" "13.2" "6"
echo %ERRORLEVEL%
```

The first command must print exactly one `RESULT=<error>` line and the following
`echo` must print `1`. The batch wrapper itself cannot be executed natively by the
macOS test runner, so the runner performs static checks for its required command,
quoting, output, and exit-code structure. Complete wrapper execution should be
validated on the Windows host used by Vantage.
