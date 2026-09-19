@echo off
REM Server Tester - Quick Launch (Windows)

setlocal

where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
    set PS=pwsh
) else (
    set PS=powershell
)

%PS% -NoProfile -ExecutionPolicy Bypass -File "%~dp0ServerTester.ps1" %*

endlocal