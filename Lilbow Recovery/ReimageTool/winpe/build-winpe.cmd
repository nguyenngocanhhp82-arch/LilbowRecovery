@echo off
REM ============================================================================
REM build-winpe.cmd  v1.1
REM Chay trong "Deployment and Imaging Tools Environment" bang quyen Administrator.
REM Phu thuoc: Windows ADK + WinPE add-on da cai.
REM
REM CANH BAO: KHONG chay tren may phat trien.
REM           Chi chay tren may build co ADK, hoac trong VM build.
REM ============================================================================
REM v1.1: Tu dong xu ly efisys_EX.bin bi thieu (ADK 10 compatibility fix)
REM ============================================================================
setlocal EnableDelayedExpansion

:: ── Kiem tra quyen Administrator ─────────────────────────────────────────────
net session >nul 2>&1
if errorlevel 1 (
    echo [LOI] Phai chay bang quyen Administrator trong "Deployment and Imaging Tools Environment".
    echo       Chuot phai vao shortcut -> "Run as administrator"
    pause & exit /b 1
)

:: ── Duong dan ADK ─────────────────────────────────────────────────────────────
set WINPE=C:\WinPE_amd64
set ADK_ROOT=C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit
set PKG="%ADK_ROOT%\Windows Preinstallation Environment\amd64\WinPE_OCs"
set OSCDIMG="%ADK_ROOT%\Deployment Tools\amd64\Oscdimg"
set MOUNT=%WINPE%\mount

:: Kiem tra ADK WinPE OCs ton tai
if not exist %PKG% (
    echo [LOI] Khong tim thay WinPE OCs tai: %PKG%
    echo       Cai Windows ADK va WinPE add-on truoc.
    echo       Tai tai: https://go.microsoft.com/fwlink/?linkid=2243391
    pause & exit /b 1
)

:: ── [FIX] Tu dong tao efisys_EX.bin neu thieu (ADK 10 vs ADK 11) ──────────────
set OSCDIMG_DIR=%ADK_ROOT%\Deployment Tools\amd64\Oscdimg
set EFI_EX=%OSCDIMG_DIR%\efisys_EX.bin
set EFI_SRC=%OSCDIMG_DIR%\efisys.bin

if not exist "%EFI_EX%" (
    echo [WARN] Khong tim thay efisys_EX.bin -- day la van de cua ADK 10.
    if exist "%EFI_SRC%" (
        echo [FIX]  Dang tao efisys_EX.bin tu efisys.bin...
        copy /y "%EFI_SRC%" "%EFI_EX%" >nul
        if errorlevel 1 (
            echo [LOI]  Khong tao duoc efisys_EX.bin - kiem tra quyen ghi thu muc ADK.
            pause & exit /b 1
        )
        echo [FIX]  Da tao efisys_EX.bin thanh cong.
    ) else (
        echo [LOI]  Khong tim thay ca efisys.bin -- ADK chua cai dung.
        echo        Kiem tra tai: %OSCDIMG_DIR%
        pause & exit /b 1
    )
) else (
    echo [INFO] efisys_EX.bin: OK
)

:: ── Don dep neu con mount cu ──────────────────────────────────────────────────
dism /Get-MountedImageInfo 2>nul | findstr /i "mount\|%MOUNT%" >nul 2>&1
if not errorlevel 1 (
    echo [WARN] Con anh dang duoc mount. Dang unmount...
    dism /Unmount-Image /MountDir:"%MOUNT%" /Discard 2>nul
)
if exist "%WINPE%" (
    echo [INFO] Xoa thu muc cu: %WINPE%
    rmdir /s /q "%WINPE%"
)

:: ── Tao co so WinPE ───────────────────────────────────────────────────────────
echo [INFO] Tao co so WinPE amd64...
call copype amd64 "%WINPE%"
if errorlevel 1 (
    echo [LOI] copype that bai.
    echo.
    echo Kiem tra:
    echo   1. Chay "Deployment and Imaging Tools Environment" bang quyen Admin
    echo   2. WinPE add-on da cai: https://go.microsoft.com/fwlink/?linkid=2243391
    echo   3. Thu muc %WINPE% co the bi khoa boi AV
    pause & exit /b 1
)

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

    :: Them goi ngon ngu (en-us bat buoc cho WinPE co PowerShell)
    if exist %PKG%\en-us\%%P_en-us.cab (
        dism /Image:"%MOUNT%" /Add-Package /PackagePath:%PKG%\en-us\%%P_en-us.cab
        if errorlevel 1 ( echo [WARN] Khong them duoc %%P_en-us -- tiep tuc. )
    )
)

:: ── Them goi Net Tcp IP (can cho WinPE co mang) ──────────────────────────────
if exist %PKG%\WinPE-NetFx.cab (
    echo   -- Kiem tra WinPE-WMI-Setup...
    if exist %PKG%\WinPE-WMI-Setup.cab (
        dism /Image:"%MOUNT%" /Add-Package /PackagePath:%PKG%\WinPE-WMI-Setup.cab 2>nul
    )
)

:: ── Nap driver neu co ────────────────────────────────────────────────────────
set DRIVER_DIR=%~dp0drivers
if exist "%DRIVER_DIR%\" (
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
    echo :: Cho network khoi dong
    echo ping -n 3 127.0.0.1 ^>nul
    echo powershell -NoProfile -ExecutionPolicy Bypass -File X:\engine.ps1
) > "%MOUNT%\Windows\System32\startnet.cmd"

:: ── Dat bien moi truong WinPE (tu dong gan chu cai) ──────────────────────────
echo [INFO] Dat bien moi truong WinPE...
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WinPE" /v "DefaultLocale" /t REG_SZ /d "en-US" /f >nul 2>&1

:: ── Commit va unmount ─────────────────────────────────────────────────────────
echo [INFO] Unmount va commit (co the mat 3-5 phut)...
dism /Unmount-Image /MountDir:"%MOUNT%" /Commit
if errorlevel 1 ( echo [LOI] Commit that bai. & pause & exit /b 1 )

:: ── Chep sang dist\ ──────────────────────────────────────────────────────────
mkdir "%~dp0dist" 2>nul
copy /y "%WINPE%\media\sources\boot.wim" "%~dp0dist\boot.wim"
if errorlevel 1 ( echo [LOI] Khong chep duoc boot.wim sang dist\. & pause & exit /b 1 )

copy /y "%WINPE%\media\boot\boot.sdi"    "%~dp0dist\boot.sdi"
if errorlevel 1 ( echo [WARN] Khong chep duoc boot.sdi -- co the chay tiep. )

echo.
echo ====================================================
echo [HOAN TAT] Build WinPE xong!
echo ====================================================
echo   boot.wim : %~dp0dist\boot.wim
echo   boot.sdi : %~dp0dist\boot.sdi
echo.
echo Buoc tiep theo:
echo   1. Kiem tra kich thuoc boot.wim (thuong 500-700 MB)
echo      dir "%~dp0dist\boot.wim"
echo.
echo   2. Tao ISO thu nghiem trong VM:
echo      MakeWinPEMedia /ISO "%WINPE%" C:\WinPE_test.iso
echo.
echo   3. Upload len GitHub Releases v1.0.0:
echo      - %~dp0dist\boot.wim
echo      - %~dp0dist\boot.sdi
echo.
echo   4. Gan ISO vao Hyper-V / VMware va boot thu.
echo      Trong WinPE chay: Get-Disk, Get-Partition
echo      Xem log tai: X:\engine.log
echo ====================================================
pause
goto :eof

:unmount_discard
echo [INFO] Huy mount (discard)...
dism /Unmount-Image /MountDir:"%MOUNT%" /Discard
echo [THAT BAI] Kiem tra log DISM tai: %WINDIR%\Logs\DISM\dism.log
pause
exit /b 1
