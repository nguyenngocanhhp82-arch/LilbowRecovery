@echo off
REM ============================================================================
REM  Deploy-ReimageTool.bat
REM  Cai dat ReimageTool len may can backup.
REM
REM  Yeu cau:
REM    - Chay voi quyen Administrator
REM    - boot.wim va boot.sdi phai nam cung thu muc voi file nay
REM      (hoac trong thu muc con "dist\")
REM    - O luu anh (mac dinh D:) phai la NTFS, KHONG PHAI o Windows
REM    - BitLocker phai tat tren C: va o luu anh
REM
REM  Cu phap:
REM    Deploy-ReimageTool.bat              (o luu anh = D:, mac dinh)
REM    Deploy-ReimageTool.bat E            (o luu anh = E:)
REM    Deploy-ReimageTool.bat D uninstall  (go cai dat)
REM
REM  CANH BAO: Script nay se thay doi BCD cua may. Khong chay tren
REM            may phat trien hoac may khong co o luu anh rieng.
REM ============================================================================
setlocal EnableDelayedExpansion

:: ── Mau sac cho terminal (ANSI) ──────────────────────────────────────────────
set RED=[91m
set GRN=[92m
set YEL=[93m
set CYN=[96m
set RST=[0m

:: ── Tham so ──────────────────────────────────────────────────────────────────
set STORE_LETTER=%~1
set MODE=%~2
if "%STORE_LETTER%"=="" set STORE_LETTER=D
if /i "%MODE%"=="uninstall" goto :UNINSTALL

set STORE=%STORE_LETTER%:
set BASE=%STORE%\Reimage

echo.
echo %CYN%============================================================%RST%
echo %CYN%   ReimageTool — Cai dat may backup%RST%
echo %CYN%============================================================%RST%
echo.

:: ══════════════════════════════════════════════════════════════════════════════
:: BUOC 1: Kiem tra quyen Administrator
:: ══════════════════════════════════════════════════════════════════════════════
echo %YEL%[1/8] Kiem tra quyen Administrator...%RST%
net session >nul 2>&1
if errorlevel 1 (
    echo %RED%[LOI] Can quyen Administrator.%RST%
    echo       Nhan chuot phai vao file nay, chon "Run as administrator".
    pause & exit /b 1
)
echo %GRN%      OK: Dang chay voi quyen Administrator.%RST%

:: ══════════════════════════════════════════════════════════════════════════════
:: BUOC 2: Kiem tra o luu anh khong phai o Windows
:: ══════════════════════════════════════════════════════════════════════════════
echo %YEL%[2/8] Kiem tra o luu anh (%STORE%)...%RST%

:: Khong duoc la C:
if /i "%STORE_LETTER%"=="C" (
    echo %RED%[LOI] Khong duoc dung o Windows (C:) lam o luu anh.%RST%
    echo       Chay lai voi ten o khac: Deploy-ReimageTool.bat D
    pause & exit /b 1
)

:: O phai ton tai
if not exist "%STORE%\" (
    echo %RED%[LOI] Khong tim thay o %STORE%. Kiem tra ten o va ket noi.%RST%
    pause & exit /b 1
)

:: Kiem tra phan vung Windows tren o nguon (C:) khac o luu anh
for /f "tokens=*" %%a in ('powershell -NoProfile -Command ^
    "if (Test-Path C:\Windows\System32) { 'yes' } else { 'no' }"') do set WIN_CHECK=%%a
if /i "%WIN_CHECK%"=="no" (
    echo %RED%[LOI] Khong tim thay C:\Windows\System32. May nay co van de.%RST%
    pause & exit /b 1
)
echo %GRN%      OK: O luu anh la %STORE%, o Windows la C:.%RST%

:: ══════════════════════════════════════════════════════════════════════════════
:: BUOC 3: Kiem tra file he thong (NTFS) bang PowerShell
:: ══════════════════════════════════════════════════════════════════════════════
echo %YEL%[3/8] Kiem tra he thong tap tin tren %STORE%...%RST%
for /f "tokens=*" %%a in ('powershell -NoProfile -Command ^
    "(Get-Volume -DriveLetter %STORE_LETTER% -ErrorAction SilentlyContinue).FileSystem"') do set FS=%%a

if /i not "%FS%"=="NTFS" (
    echo %RED%[LOI] O %STORE% khong phai NTFS (hien tai: %FS%).%RST%
    echo       Format o nay thanh NTFS truoc khi cai dat.
    pause & exit /b 1
)
echo %GRN%      OK: %STORE% la NTFS.%RST%

:: ══════════════════════════════════════════════════════════════════════════════
:: BUOC 4: Kiem tra BitLocker
:: ══════════════════════════════════════════════════════════════════════════════
echo %YEL%[4/8] Kiem tra BitLocker...%RST%

for /f "tokens=*" %%a in ('powershell -NoProfile -Command ^
    "(Get-BitLockerVolume -MountPoint C: -EA SilentlyContinue).VolumeStatus"') do set BL_C=%%a
for /f "tokens=*" %%a in ('powershell -NoProfile -Command ^
    "(Get-BitLockerVolume -MountPoint %STORE% -EA SilentlyContinue).VolumeStatus"') do set BL_STORE=%%a

if /i not "%BL_C%"=="FullyDecrypted" if not "%BL_C%"=="" (
    echo %RED%[LOI] BitLocker dang bat tren C: (Trang thai: %BL_C%).%RST%
    echo       Giai ma BitLocker hoan toan truoc khi cai dat.
    echo       Lenh kiem tra: manage-bde -status C:
    pause & exit /b 1
)
if /i not "%BL_STORE%"=="FullyDecrypted" if not "%BL_STORE%"=="" (
    echo %RED%[LOI] BitLocker dang bat tren %STORE% (Trang thai: %BL_STORE%).%RST%
    echo       Giai ma BitLocker hoan toan truoc khi cai dat.
    pause & exit /b 1
)
echo %GRN%      OK: BitLocker tat tren C: va %STORE%.%RST%

:: ══════════════════════════════════════════════════════════════════════════════
:: BUOC 5: Kiem tra cho trong tren o luu anh
:: ══════════════════════════════════════════════════════════════════════════════
echo %YEL%[5/8] Kiem tra cho trong...%RST%

for /f "tokens=*" %%a in ('powershell -NoProfile -Command ^
    "[math]::Round((Get-PSDrive %STORE_LETTER%).Free/1GB, 1)"') do set FREE_GB=%%a

:: Can it nhat 20 GB cho boot.wim (~500 MB) + it nhat 1 anh (~10-15 GB)
for /f "tokens=*" %%a in ('powershell -NoProfile -Command ^
    "if ((Get-PSDrive %STORE_LETTER%).Free -ge 20GB) { 'ok' } else { 'low' }"') do set SPACE_CHECK=%%a

if /i "%SPACE_CHECK%"=="low" (
    echo %RED%[CANH BAO] O %STORE% con it hon 20 GB (hien tai: %FREE_GB% GB).%RST%
    echo           Can it nhat 20 GB de luu boot.wim va it nhat 1 anh backup.
    set /p CONTINUE_ANYWAY=Tiep tuc anyway? (y/N): 
    if /i not "!CONTINUE_ANYWAY!"=="y" ( echo Da huy. & exit /b 0 )
) else (
    echo %GRN%      OK: Con %FREE_GB% GB trong tren %STORE%.%RST%
)

:: ══════════════════════════════════════════════════════════════════════════════
:: BUOC 6: Tim file boot.wim va boot.sdi
:: ══════════════════════════════════════════════════════════════════════════════
echo %YEL%[6/8] Tim file WinPE (boot.wim, boot.sdi)...%RST%

set WIM_SRC=
set SDI_SRC=

:: Thu muc canh file nay
if exist "%~dp0boot.wim" (
    set WIM_SRC=%~dp0boot.wim
    set SDI_SRC=%~dp0boot.sdi
) else if exist "%~dp0dist\boot.wim" (
    set WIM_SRC=%~dp0dist\boot.wim
    set SDI_SRC=%~dp0dist\boot.sdi
)

if not defined WIM_SRC (
    echo %RED%[LOI] Khong tim thay boot.wim.%RST%
    echo       Dam bao boot.wim va boot.sdi nam cung thu muc voi Deploy-ReimageTool.bat.
    echo       Neu chua build WinPE, chay build-winpe.cmd tren may phat trien truoc.
    pause & exit /b 1
)
if not exist "%SDI_SRC%" (
    echo %RED%[LOI] Tim thay boot.wim nhung thieu boot.sdi.%RST%
    pause & exit /b 1
)
echo %GRN%      OK: boot.wim = %WIM_SRC%%RST%
echo %GRN%          boot.sdi = %SDI_SRC%%RST%

:: ══════════════════════════════════════════════════════════════════════════════
:: BUOC 7: Kiem tra da cai truoc chua (tranh tao BCD trung)
:: ══════════════════════════════════════════════════════════════════════════════
echo %YEL%[7/8] Kiem tra trang thai cai dat truoc do...%RST%

set GUID_FILE=%BASE%\bootguid.txt
set SKIP_BCD=0

if exist "%GUID_FILE%" (
    set /p OLD_GUID=<"%GUID_FILE%"
    echo       Tim thay bootguid.txt: !OLD_GUID!
    bcdedit /enum all | findstr /i "!OLD_GUID!" >nul 2>&1
    if not errorlevel 1 (
        echo %GRN%      OK: Muc BCD da ton tai. Se cap nhat file WinPE nhung giu BCD cu.%RST%
        set SKIP_BCD=1
    ) else (
        echo %YEL%      CANH BAO: bootguid.txt co nhung muc BCD da mat. Se tao lai.%RST%
        del /f "%GUID_FILE%" 2>nul
    )
)

:: ══════════════════════════════════════════════════════════════════════════════
:: BUOC 8: Tao thu muc, chep file, tao BCD (neu can)
:: ══════════════════════════════════════════════════════════════════════════════
echo %YEL%[8/8] Cai dat...%RST%

:: Tao cay thu muc
mkdir "%BASE%\sources"      2>nul
mkdir "%BASE%\boot"         2>nul
mkdir "%BASE%\images\_tmp"  2>nul
mkdir "%BASE%\logs"         2>nul
echo       Tao thu muc: %BASE%

:: Chep boot.wim va boot.sdi
echo       Chep boot.wim (co the mat vai phut)...
copy /y "%WIM_SRC%" "%BASE%\sources\boot.wim" >nul
if errorlevel 1 ( echo %RED%[LOI] Khong chep duoc boot.wim.%RST% & pause & exit /b 1 )
copy /y "%SDI_SRC%" "%BASE%\boot\boot.sdi" >nul
if errorlevel 1 ( echo %RED%[LOI] Khong chep duoc boot.sdi.%RST% & pause & exit /b 1 )
echo %GRN%      Chep file xong.%RST%

:: Tao BCD neu chua co
if "%SKIP_BCD%"=="0" (
    echo       Tao muc BCD ramdisk...
    bcdedit /create {ramdiskoptions} /d "Reimage Ramdisk" >nul 2>&1
    bcdedit /set {ramdiskoptions} ramdisksdidevice partition=%STORE%  >nul
    bcdedit /set {ramdiskoptions} ramdisksdipath \Reimage\boot\boot.sdi  >nul

    for /f "tokens=2 delims={}" %%a in (
        'bcdedit /create /d "ReimageTool WinPE" /application osloader'
    ) do set NEW_GUID={%%a}

    if not defined NEW_GUID (
        echo %RED%[LOI] Tao muc BCD that bai. Kiem tra quyen Administrator va UEFI.%RST%
        pause & exit /b 1
    )

    bcdedit /set %NEW_GUID% device    ramdisk=[%STORE%]\Reimage\sources\boot.wim,{ramdiskoptions}  >nul
    bcdedit /set %NEW_GUID% osdevice  ramdisk=[%STORE%]\Reimage\sources\boot.wim,{ramdiskoptions}  >nul
    bcdedit /set %NEW_GUID% path      \windows\system32\boot\winload.efi  >nul
    bcdedit /set %NEW_GUID% systemroot \windows  >nul
    bcdedit /set %NEW_GUID% winpe     yes  >nul
    bcdedit /set %NEW_GUID% detecthal yes  >nul
    bcdedit /displayorder %NEW_GUID% /addlast  >nul

    echo %NEW_GUID%>"%GUID_FILE%"
    echo %GRN%      Tao muc BCD: %NEW_GUID%%RST%
)

:: Dat quyen va thuoc tinh an
attrib +h "%BASE%"  >nul 2>&1
icacls "%BASE%" /inheritance:r /grant:r "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" >nul 2>&1
echo       Dat quyen truy cap: chi Administrators va SYSTEM.

:: ══════════════════════════════════════════════════════════════════════════════
:: HOAN TAT
:: ══════════════════════════════════════════════════════════════════════════════
echo.
echo %GRN%============================================================%RST%
echo %GRN%  CAI DAT HOAN TAT!%RST%
echo %GRN%============================================================%RST%
echo.
echo  May tinh: %COMPUTERNAME%
echo  O luu anh: %STORE%
if defined NEW_GUID (
    echo  Boot GUID: %NEW_GUID%
) else (
    echo  Boot GUID: !OLD_GUID! (cu, giu nguyen)
)
echo  Thu muc  : %BASE%
echo.
echo  BUOC TIEP THEO:
echo    1. Mo ReimageTool.exe (khi co) de chon Backup/Restore
echo    HOAC
echo    1. Chay: scripts\Start-Job.ps1 -Action backup -WhatIf
echo       de kiem tra cai gi se xay ra truoc khi chay that.
echo.
if exist "%GUID_FILE%" (
    echo  Kiem tra BCD:  bcdedit /enum all
    echo  Kiem tra file: dir /a %BASE%
)
echo.
pause
goto :eof

:: ══════════════════════════════════════════════════════════════════════════════
:UNINSTALL
:: ══════════════════════════════════════════════════════════════════════════════
echo.
echo %YEL%============================================================%RST%
echo %YEL%  Go cai dat ReimageTool khoi %STORE%%RST%
echo %YEL%============================================================%RST%
echo.

net session >nul 2>&1
if errorlevel 1 ( echo %RED%[LOI] Can quyen Administrator.%RST% & pause & exit /b 1 )

set GUID_FILE=%BASE%\bootguid.txt

if not exist "%GUID_FILE%" (
    echo %YEL%[CANH BAO] Khong tim thay bootguid.txt — co the chua cai hoac da go.%RST%
    goto :ask_delete
)

set /p BOOT_GUID=<"%GUID_FILE%"
echo  Se xoa muc BCD: %BOOT_GUID%
echo.

bcdedit /enum all | findstr /i "%BOOT_GUID%" >nul 2>&1
if not errorlevel 1 (
    bcdedit /displayorder %BOOT_GUID% /remove >nul
    bcdedit /delete %BOOT_GUID% /f >nul
    echo %GRN%  Da xoa muc BCD.%RST%
) else (
    echo %YEL%  Muc BCD khong con trong BCD (co the da xoa thu cong).%RST%
)
del /f "%GUID_FILE%" 2>nul

:ask_delete
echo.
set /p DEL_DIR=Ban co muon xoa toan bo %BASE%\ (bao gom tat ca anh backup)? [y/N]: 
if /i "%DEL_DIR%"=="y" (
    echo  Dang xoa %BASE%...
    attrib -h "%BASE%" >nul 2>&1
    icacls "%BASE%" /reset /t /c >nul 2>&1
    rmdir /s /q "%BASE%"
    echo %GRN%  Da xoa %BASE%.%RST%
) else (
    echo  Giu lai thu muc %BASE% (ảnh backup van con do).
)
echo.
echo %GRN%  Go cai dat hoan tat.%RST%
pause
