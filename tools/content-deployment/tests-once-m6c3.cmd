@echo off
rem M6-C2 tooling dry run: ONE run of the frozen M6-B1 hardening native test executable (626e4a5a..., preserved copy).
rem   tests-once-m6c3.cmd <native-log-dir> <tests-exe> <output-file>
setlocal enabledelayedexpansion
set GLACIERRELAY_LOG_DIR=%~1
%~2 > %3 2>&1
echo EXIT=!ERRORLEVEL!
