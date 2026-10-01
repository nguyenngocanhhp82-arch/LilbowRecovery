@echo off
:: ============================================================================
::  ReimageTool.bat — Launcher chinh
::  Double-click de chay. Tu dong leo quyen Administrator.
::  Dat file nay cung thu muc voi ReimageTool.ps1, boot.wim, boot.sdi
:: ============================================================================
:: Kiem tra quyen Admin, neu chua co thi tu nang cap
net session >nul 2>&1
if errorlevel 1 (
    echo Dang yeu cau quyen Administrator...
    powershell -NoProfile -Command ^
        "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

:: Chuyen den thu muc chua file bat nay
cd /d "%~dp0"

:: Chay script chinh
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ReimageTool.ps1"

:: Giu cua so neu script thoat dot ngot
if errorlevel 1 (
    echo.
    echo Script ket thuc voi loi. Nhan phim bat ky de dong...
    pause >nul
)
