@echo off
REM ============================================================================
REM build-winpe.cmd
REM Chay trong "Deployment and Imaging Tools Environment" bang quyen Administrator.
REM Phu thuoc: Windows ADK + WinPE add-on da cai.
REM
REM CANH BAO: KHONG chay tren may phat trien.
REM           Chi chay tren may build co ADK, hoac trong VM build.
REM ============================================================================
REM TRANG THAI: Ban khoi dau — chua thu nghiem tren may that (Phu luc A.4)
REM ============================================================================
setlocal EnableDelayedExpansion

:: ── Kiem tra quyen Administrator ─────────────────────────────────────────────
net session >nul 2>&1
if errorlevel 1 (
    echo [LOI] Phai chay bang quyen Administrator trong "Deployment and Imaging Tools Environment".
    pause & exit /b 1
)

:: ── Duong dan ADK ─────────────────────────────────────────────────────────────
set WINPE=C:\WinPE_amd64
set ADK_ROOT=C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit
set PKG="%ADK_ROOT%\Windows Preinstallation Environment\amd64\WinPE_OCs"
set MOUNT=%WINPE%\mount

:: Kiem tra ADK ton tai
if not exist %PKG% (
    echo [LOI] Khong tim thay WinPE OCs tai: %PKG%
    echo       Cai Windows ADK va WinPE add-on truoc.
    pause & exit /b 1
)

:: ── Don dep neu con mount cu ──────────────────────────────────────────────────
dism /Get-MountedImageInfo 2>nul | findstr /i "mount\|%MOUNT%" >nul 2>&1
if not errorlevel 1 (
    echo [WARN] Con anh dang duoc mount. Dang unmount...
    dism /Unmount-Image /MountDir:"%MOUNT%" /Discard 2>nul
)
if exist "%WINPE%" rmdir /s /q "%WINPE%"

:: ── Tao co so WinPE ───────────────────────────────────────────────────────────
echo [INFO] Tao co so WinPE amd64...
call copype amd64 "%WINPE%"
if errorlevel 1 ( echo [LOI] copype that bai. & pause & exit /b 1 )

:: ── Mount boot.wim ────────────────────────────────────────────────────────────
echo [INFO] Mounting boot.wim...
dism /Mount-Image /ImageFile:"%WINPE%\media\sources\boot.wim" /Index:1 /MountDir:"%MOUNT%"
if errorlevel 1 ( echo [LOI] Mount that bai. & pause & exit /b 1 )

:: ── Them goi theo thu tu dung (co phu thuoc lan nhau) ────────────────────────
echo [INFO] Them cac goi WinPE...
for %%P in (WinPE-WMI WinPE-NetFx WinPE-Scripting WinPE-PowerShell WinPE-StorageWMI WinPE-DismCmdlets WinPE-SecureStartup) do (
    echo   -- Them %%P...
    dism /Image:"%MOUNT%" /Add-Package /PackagePath:%PKG%\%%P.cab
    if errorlevel 1 ( echo [LOI] Them %%P that bai. & goto :unmount_discard )
    dism /Image:"%MOUNT%" /Add-Package /PackagePath:%PKG%\en-us\%%P_en-us.cab
    if errorlevel 1 ( echo [LOI] Them %%P_en-us that bai. & goto :unmount_discard )
)

:: ── Nap driver neu co ────────────────────────────────────────────────────────
set DRIVER_DIR=%~dp0drivers
if exist "%DRIVER_DIR%\" (
    :: Kiem tra co driver khong (khong chi co .gitkeep)
    dir /a-d /b "%DRIVER_DIR%\*.inf" >nul 2>&1
    if not errorlevel 1 (
        echo [INFO] Nap driver tu: %DRIVER_DIR%
        dism /Image:"%MOUNT%" /Add-Driver /Driver:"%DRIVER_DIR%" /Recurse
    ) else (
        echo [INFO] Thu muc drivers rong, bo qua.
    )
) else (
    echo [INFO] Khong co thu muc drivers, bo qua.
)

:: ── Chep engine.ps1 va ghi startnet.cmd ──────────────────────────────────────
echo [INFO] Chep engine.ps1...
copy /y "%~dp0engine.ps1" "%MOUNT%\engine.ps1"
if errorlevel 1 ( echo [LOI] Khong chep duoc engine.ps1. & goto :unmount_discard )

echo [INFO] Ghi startnet.cmd...
(
    echo wpeinit
    echo powershell -NoProfile -ExecutionPolicy Bypass -File X:\engine.ps1
) > "%MOUNT%\Windows\System32\startnet.cmd"

:: ── Commit va unmount ─────────────────────────────────────────────────────────
echo [INFO] Unmount va commit...
dism /Unmount-Image /MountDir:"%MOUNT%" /Commit
if errorlevel 1 ( echo [LOI] Commit that bai. & pause & exit /b 1 )

:: ── Chep sang dist\ ──────────────────────────────────────────────────────────
mkdir "%~dp0dist" 2>nul
copy /y "%WINPE%\media\sources\boot.wim" "%~dp0dist\boot.wim"
copy /y "%WINPE%\media\boot\boot.sdi"    "%~dp0dist\boot.sdi"

echo.
echo [HOAN TAT] Build WinPE xong.
echo   boot.wim : %~dp0dist\boot.wim
echo   boot.sdi : %~dp0dist\boot.sdi
echo.
echo Buoc tiep theo:
echo   1. Tao ISO thu: MakeWinPEMedia /ISO "%WINPE%" C:\WinPE_test.iso
echo   2. Gan ISO vao VM va boot thu
echo   3. Trong WinPE: chay 'powershell', 'Get-Disk', 'Get-Partition'
pause
goto :eof

:unmount_discard
echo [INFO] Huy mount (discard)...
dism /Unmount-Image /MountDir:"%MOUNT%" /Discard
echo [THAT BAI] Kiem tra log DISM tai: %WINDIR%\Logs\DISM\dism.log
pause
exit /b 1
