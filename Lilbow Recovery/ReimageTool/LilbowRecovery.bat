@echo off
:: ============================================================================
::  LilbowRecovery.bat — Launcher chinh
::  Double-click de chay. Tu dong leo quyen Administrator.
::  Dat file nay cung thu muc voi ReimageTool.ps1, boot.wim, boot.sdi
:: ============================================================================
net session >nul 2>&1
if errorlevel 1 (
    echo Dang yeu cau quyen Administrator...
    powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ReimageTool.ps1"
if errorlevel 1 (
    echo.
    echo Ung dung thoat voi loi. Nhan phim bat ky de dong...
    pause >nul
)
