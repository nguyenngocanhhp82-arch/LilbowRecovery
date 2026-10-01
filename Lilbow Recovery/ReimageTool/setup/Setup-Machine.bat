@echo off
REM ============================================================================
REM Setup-Machine.bat
REM Chay mot lan moi may, quyen Administrator.
REM boot.wim va boot.sdi nam canh file nay (hoac trong thu muc dist\).
REM
REM Cu phap: Setup-Machine.bat [TEN_O]
REM Vi du:   Setup-Machine.bat D
REM          Setup-Machine.bat E
REM
REM CANH BAO: Khong chay file nay tren may phat trien.
REM           Chi chay trong VM Hyper-V hoac may lab.
REM ============================================================================
REM TRANG THAI: Ban khoi dau — chua thu nghiem tren may that (Phu luc A.1)
REM ============================================================================

:: Lay tham so o luu anh, mac dinh D
set STORE=%~1
if "%STORE%"=="" set STORE=D
set STORE_ROOT=%STORE%:

:: ── Kiem tra quyen Administrator ─────────────────────────────────────────────
net session >nul 2>&1
if errorlevel 1 (
    echo [LOI] Can quyen Administrator. Chay lai bang "Run as administrator".
    pause & exit /b 1
)

:: ── Kiem tra o luu anh khong phai o Windows ─────────────────────────────────
if /i "%STORE%"=="C" (
    echo [LOI] Khong duoc dung o Windows (C:) lam o luu anh.
    pause & exit /b 1
)

:: ── Kiem tra o ton tai ───────────────────────────────────────────────────────
if not exist "%STORE_ROOT%\" (
    echo [LOI] Khong tim thay o %STORE_ROOT%. Kiem tra lai ten o.
    pause & exit /b 1
)

:: ── Kiem tra bootguid.txt da ton tai (tranh tao BCD trung) ──────────────────
set GUID_FILE=%STORE_ROOT%\Reimage\bootguid.txt
if exist "%GUID_FILE%" (
    set /p EXISTING_GUID=<"%GUID_FILE%"
    echo [INFO] Da tim thay bootguid.txt: %EXISTING_GUID%
    echo [INFO] Kiem tra muc BCD con ton tai khong...
    bcdedit /enum all | findstr /i "%EXISTING_GUID%" >nul 2>&1
    if not errorlevel 1 (
        echo [OK] Muc BCD da ton tai. Bo qua buoc tao BCD.
        goto :copy_files
    ) else (
        echo [WARN] Muc BCD cu khong con trong BCD. Se tao lai.
    )
)

:: ── Tao cay thu muc ──────────────────────────────────────────────────────────
echo [INFO] Tao cay thu muc...
mkdir "%STORE_ROOT%\Reimage\sources"   2>nul
mkdir "%STORE_ROOT%\Reimage\boot"      2>nul
mkdir "%STORE_ROOT%\Reimage\images\_tmp" 2>nul
mkdir "%STORE_ROOT%\Reimage\logs"      2>nul

:copy_files
:: ── Chep boot.wim va boot.sdi ────────────────────────────────────────────────
set SCRIPT_DIR=%~dp0
if exist "%SCRIPT_DIR%boot.wim" (
    echo [INFO] Chep boot.wim va boot.sdi...
    copy /y "%SCRIPT_DIR%boot.wim" "%STORE_ROOT%\Reimage\sources\boot.wim" >nul
    copy /y "%SCRIPT_DIR%boot.sdi" "%STORE_ROOT%\Reimage\boot\boot.sdi"   >nul
) else if exist "%SCRIPT_DIR%dist\boot.wim" (
    copy /y "%SCRIPT_DIR%dist\boot.wim" "%STORE_ROOT%\Reimage\sources\boot.wim" >nul
    copy /y "%SCRIPT_DIR%dist\boot.sdi" "%STORE_ROOT%\Reimage\boot\boot.sdi"   >nul
) else (
    echo [LOI] Khong tim thay boot.wim. Chay build-winpe.cmd truoc.
    pause & exit /b 1
)

:: ── Tao muc BCD ramdisk ───────────────────────────────────────────────────────
:: (Chi thuc hien neu chua co muc BCD hop le)
if exist "%GUID_FILE%" goto :set_permissions

echo [INFO] Tao BCD ramdisk options...
bcdedit /create {ramdiskoptions} /d "Reimage Ramdisk" 2>nul
bcdedit /set {ramdiskoptions} ramdisksdidevice partition=%STORE_ROOT%
bcdedit /set {ramdiskoptions} ramdisksdipath \Reimage\boot\boot.sdi

echo [INFO] Tao muc boot WinPE...
for /f "tokens=2 delims={}" %%a in ('bcdedit /create /d "Reimage WinPE" /application osloader') do set NEW_GUID={%%a}

bcdedit /set %NEW_GUID% device ramdisk=[%STORE_ROOT%]\Reimage\sources\boot.wim,{ramdiskoptions}
bcdedit /set %NEW_GUID% osdevice ramdisk=[%STORE_ROOT%]\Reimage\sources\boot.wim,{ramdiskoptions}
bcdedit /set %NEW_GUID% path \windows\system32\boot\winload.efi
bcdedit /set %NEW_GUID% systemroot \windows
bcdedit /set %NEW_GUID% winpe yes
bcdedit /set %NEW_GUID% detecthal yes
bcdedit /displayorder %NEW_GUID% /addlast

echo %NEW_GUID%>"%GUID_FILE%"
echo [OK] Muc BCD da tao: %NEW_GUID%

:set_permissions
:: ── Dat thuoc tinh an va quyen truy cap ──────────────────────────────────────
echo [INFO] Dat quyen truy cap...
attrib +h "%STORE_ROOT%\Reimage"
icacls "%STORE_ROOT%\Reimage" /inheritance:r /grant:r "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" >nul

echo.
echo [HOAN TAT] Setup-Machine da chay xong.
echo Kiem tra: %STORE_ROOT%\Reimage\bootguid.txt
echo Kiem tra: bcdedit /enum all
pause
