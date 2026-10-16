@echo off
setlocal
cd /d "%~1" || exit /b 91
echo === DEPLOY START %DATE% %TIME%
echo === effective config.json
type config.json
echo === Deploy.exe --useConsoleLogging --doNotPause --logLevel verbose --logLevel debug --logLevel info --logLevel warn --logLevel error
Deploy.exe --useConsoleLogging --doNotPause --logLevel verbose --logLevel debug --logLevel info --logLevel warn --logLevel error
set RC=%ERRORLEVEL%
echo === DEPLOY END %DATE% %TIME% rc=%RC%
exit /b %RC%
