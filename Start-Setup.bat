@echo off
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Setup.ps1"
if errorlevel 1 (
    echo.
    echo Windows Setup Manager exited with an error.
    pause
)
