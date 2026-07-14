@echo off
setlocal
powershell.exe ^
  -NoLogo ^
  -NoProfile ^
  -NonInteractive ^
  -ExecutionPolicy Bypass ^
  -File "%~dp0Normalize-WebVtt.ps1" ^
  -VttPath "%~1" ^
  -DurationSeconds "%~2" ^
  -CueIntervalSeconds "%~3"
set "SCRIPT_EXIT_CODE=%ERRORLEVEL%"
exit /b %SCRIPT_EXIT_CODE%
