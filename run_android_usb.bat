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

set "DEVICE_ID=%~1"
if not "%DEVICE_ID%"=="" goto device_selected

for /f "usebackq delims=" %%D in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$json = flutter devices --machine; $text = [string]::Join([Environment]::NewLine, $json); $devices = ConvertFrom-Json -InputObject $text; foreach ($dev in $devices) { if ($dev.targetPlatform -like 'android-*' -and -not $dev.emulator) { $dev.id; break } }"`) do set "DEVICE_ID=%%D"

:device_selected

echo.
echo Starting Local Chat on USB Android device...
echo.
echo Tip: connect phone by USB, enable Developer options ^> USB debugging,
echo then accept the "Allow USB debugging" prompt on the phone.
echo.

if "%DEVICE_ID%"=="" (
  echo No Android USB device was found.
  echo Connected devices:
  flutter devices
  pause
  exit /b 1
)

echo Device: %DEVICE_ID%
echo.

flutter run -d "%DEVICE_ID%" --device-timeout 60
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
  echo Flutter could not start the Android app.
  echo Connected devices:
  flutter devices
  echo.
  echo If your phone is missing, run: flutter doctor
)
pause
exit /b %EXIT_CODE%
