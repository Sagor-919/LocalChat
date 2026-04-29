@echo off
setlocal

cd /d "%~dp0"

where flutter >nul 2>nul
if errorlevel 1 (
  echo Flutter was not found on PATH.
  echo Open this from a terminal where Flutter works, or add Flutter to PATH.
  pause
  exit /b 1
)

set "WEB_PORT=%~1"
if "%WEB_PORT%"=="" set "WEB_PORT=8080"

echo.
echo Starting Local Chat on Chrome web...
echo URL: http://127.0.0.1:%WEB_PORT%
echo.

flutter run -d chrome --web-hostname 127.0.0.1 --web-port %WEB_PORT%
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
  echo Flutter could not start the Chrome web app.
  echo Connected devices:
  flutter devices
)
pause
exit /b %EXIT_CODE%
