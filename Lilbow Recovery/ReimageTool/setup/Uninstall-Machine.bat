@echo off
REM ============================================================================
REM Uninstall-Machine.bat
REM Xoa muc BCD theo GUID trong bootguid.txt.
REM Hoi nguoi dung co muon xoa thu muc \Reimage khong (mac dinh giu lai anh).
REM
REM CANH BAO: Khong chay tren may phat trien.
REM ============================================================================

set STORE=%~1
if "%STORE%"=="" set STORE=D
set STORE_ROOT=%STORE%:
set GUID_FILE=%STORE_ROOT%\Reimage\bootguid.txt

:: Kiem tra quyen Administrator
net session >nul 2>&1
if errorlevel 1 (
    echo [LOI] Can quyen Administrator.
    pause & exit /b 1
)

if not exist "%GUID_FILE%" (
    echo [WARN] Khong tim thay bootguid.txt. Co the chua cai dat hoac da go.
    goto :ask_delete_dir
)

set /p BOOT_GUID=<"%GUID_FILE%"
echo [INFO] Se xoa muc BCD: %BOOT_GUID%

bcdedit /enum all | findstr /i "%BOOT_GUID%" >nul 2>&1
if errorlevel 1 (
    echo [WARN] Muc BCD khong con trong BCD (co the da xoa thu cong).
) else (
    bcdedit /displayorder %BOOT_GUID% /remove
    bcdedit /delete %BOOT_GUID% /f
    echo [OK] Da xoa muc BCD.
)

del /f "%GUID_FILE%"

:ask_delete_dir
echo.
set /p ANSWER=Ban co muon xoa thu muc %STORE_ROOT%\Reimage (bao gom anh backup) khong? [y/N]: 
if /i "%ANSWER%"=="y" (
    echo [INFO] Dang xoa %STORE_ROOT%\Reimage...
    attrib -h "%STORE_ROOT%\Reimage"
    icacls "%STORE_ROOT%\Reimage" /reset /t /c >nul
    rmdir /s /q "%STORE_ROOT%\Reimage"
    echo [OK] Da xoa.
) else (
    echo [INFO] Giu lai thu muc %STORE_ROOT%\Reimage.
)

echo [HOAN TAT] Go cai dat xong.
pause
