@echo off
rem M6-C2 tooling dry run only: the frozen M6-B1 hardening command probe (4c7a93da..., preserved copy) as the
rem version-2 peer. FAKE frame source, FAKE registry / brick / entity / transform data; no engine, no game.
rem   run-probe-m6c3.cmd <native-log-dir> <probe-exe> <port> <frame_interval_ms> <duration_ms> <scene> inert ok <players-mode>
set GLACIERRELAY_LOG_DIR=%~1
%~2 %3 %4 %5 %6 %7 %8 %9
exit /b %ERRORLEVEL%
