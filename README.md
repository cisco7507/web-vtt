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

Generated cues are numbered from 1, are contiguous, and contain one U+2060 WORD
JOINER as their invisible payload. Output is UTF-8 without a BOM, uses LF line
endings on every platform, and ends with one newline. Timestamps use
`HH:MM:SS.mmm`; hours do not wrap after 24.

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
  same volume without creating a backup.
- On macOS under PowerShell 7, `.NET File.Move(source, target, true)` performs the
  overwrite rename with both paths on the same filesystem.

These operations prevent a partially written target on normal local filesystems.
Atomicity ultimately depends on the filesystem implementation; remote shares and
special filesystems may provide weaker rename guarantees. If replacement fails,
the original target remains in place and the utility attempts to remove its
temporary file.

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
