@echo off
rem M6-F offline probe phases only (the M6-F1b tooling dry run, the M6-F2a follow-up matrix): the FROZEN final M6-F1a command
rem probe (m6f1a-offline\native4\GlacierRelayCommandProbe.exe, SHA-256 4cb8cc0e435f79e5af1e9a018f8e4218cf5bfc0ee094929e4b7754be063b5a3b,
rem hash-verified by the caller; read and executed, never modified) as the version-2 peer: FAKE frame source, FAKE exact-transform
rem world, FAKE transform applier; no engine, no game, no SDK function. The native log directory and the executable are ARGUMENTS
rem (the log directory validated by the caller's evidence guard); nothing here names an evidence directory. Every further argument
rem is passed through. Identical in function to m6f1b-run1\run-probe-m6f1b.cmd.
rem   run-probe-m6f.cmd <native-log-dir> <probe-exe> <probe arguments...>
set GLACIERRELAY_LOG_DIR=%~1
set EXE=%~2
shift
shift
set ARGS=
:loop
if "%~1"=="" goto run
set ARGS=%ARGS% %1
shift
goto loop
:run
"%EXE%" %ARGS%
exit /b %ERRORLEVEL%
