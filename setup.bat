@echo off
setlocal EnableDelayedExpansion
chcp 65001 >nul 2>&1
title SUPERVOOC 80W charging fix - setup

set "DEVICE_MODEL=CPH2769"
set "DEVICE_NAME=OnePlus 15R"
set "MISSING_CONFIG=silicon_x25_X2_single_charging_hyper_mode_config.txt"
set "FASTCHG_DIR=/odm/firmware/fastchg/24877"
set "KSU_STAGE=%~dp0ksu_stage.sh"

echo.
echo ============================================
echo   SUPERVOOC 80W charging fix -- setup
echo ============================================
echo.
echo This script sets up the SUPERVOOC charging fix on your %DEVICE_NAME% (%DEVICE_MODEL%).
echo It will connect to your phone via ADB, verify the device, and push the fix script.
echo.

:: check adb
where adb >nul 2>&1
if %errorlevel% neq 0 (
    echo [-] adb not found.
    echo     Download Android SDK Platform Tools from:
    echo     https://developer.android.com/tools/releases/platform-tools
    echo     Extract it and add the folder to your PATH.
    echo.
    pause
    exit /b 1
)
echo [+] adb found.

:: check ksu_stage.sh
if not exist "%KSU_STAGE%" (
    echo [-] ksu_stage.sh not found next to this script.
    echo     Make sure you run this from the repo directory.
    echo.
    pause
    exit /b 1
)
echo [+] ksu_stage.sh found.

:: ----------------------------------------------------------------
echo.
echo === Step 1: Connect to your phone ===
echo.
echo Make sure USB debugging (or Wireless debugging) is enabled on your phone:
echo   Settings ^> About phone ^> tap Build number 7 times
echo   Settings ^> System ^> Developer options ^> USB debugging (or Wireless debugging)
echo.
echo How do you want to connect?
echo   1) USB cable
echo   2) WiFi (wireless debugging)
echo.
choice /c 12 /n /m "[?] Choose [1/2]: "
set "CONN=%errorlevel%"

if "%CONN%"=="1" goto :usb_connect
if "%CONN%"=="2" goto :wifi_connect
goto :eof

:usb_connect
echo.
echo [*] Connect your phone via USB cable, then unlock it and tap 'Allow' on the
echo     USB debugging prompt.
echo.
pause
echo.
echo [*] Waiting for device...
adb wait-for-device
echo [+] Device connected via USB.
goto :verify_device

:wifi_connect
echo.
echo [*] On your phone, go to:
echo     Developer options ^> Wireless debugging ^> Pair device with pairing code
echo.
set /p "PHONE_IP=[?] Enter the phone's IP address: "
set /p "PAIR_PORT=[?] Enter the pairing port: "
set /p "PAIR_CODE=[?] Enter the pairing code: "

echo.
echo [*] Pairing with %PHONE_IP%:%PAIR_PORT%...
adb pair %PHONE_IP%:%PAIR_PORT% %PAIR_CODE%
if %errorlevel% neq 0 (
    echo [-] Pairing failed. Check the IP, port, and code.
    pause
    exit /b 1
)
echo [+] Paired successfully.

echo.
echo [*] Now look at the Wireless debugging main screen (NOT the pairing dialog).
echo     The port shown there is the connection port.
echo.
set /p "CONN_PORT=[?] Enter the connection port: "

echo.
echo [*] Connecting to %PHONE_IP%:%CONN_PORT%...
adb connect %PHONE_IP%:%CONN_PORT%
if %errorlevel% neq 0 (
    echo [-] Connection failed.
    pause
    exit /b 1
)
echo [+] Connected via WiFi.
goto :verify_device

:: ----------------------------------------------------------------
:verify_device
echo.
echo === Step 2: Verify device ===
echo.
echo [*] Checking device model...

for /f "tokens=*" %%a in ('adb shell getprop ro.build.product 2^>nul') do set "MODEL=%%a"
for /f "tokens=*" %%a in ('adb shell getprop ro.product.model 2^>nul') do set "DISPLAY_MODEL=%%a"

:: trim carriage returns
set "MODEL=%MODEL: =%"
set "DISPLAY_MODEL=%DISPLAY_MODEL: =%"

echo [*] Detected: %DISPLAY_MODEL% (%MODEL%)

echo %MODEL% | findstr /i "%DEVICE_MODEL%" >nul 2>&1
if %errorlevel% neq 0 (
    echo %DISPLAY_MODEL% | findstr /i "%DEVICE_MODEL%" >nul 2>&1
    if !errorlevel! neq 0 (
        echo.
        echo [-] This device is '%DISPLAY_MODEL%' ^(%MODEL%^), not %DEVICE_NAME% ^(%DEVICE_MODEL%^).
        echo [-] This fix is designed specifically for the %DEVICE_NAME%.
        echo.
        choice /c YN /n /m "[?] Continue anyway? (NOT recommended) [y/N]: "
        if !errorlevel!==2 (
            echo [-] Aborted.
            pause
            exit /b 1
        )
        echo [!] Proceeding at your own risk.
    ) else (
        echo [+] Device verified.
    )
) else (
    echo [+] Device verified.
)

:: ----------------------------------------------------------------
echo.
echo === Step 3: Check charging config ===
echo.
echo [*] Checking for the missing config file...

adb shell "[ -f '%FASTCHG_DIR%/%MISSING_CONFIG%' ] && echo EXISTS || echo MISSING" > "%TEMP%\supervooc_check.txt" 2>nul
set /p "FILE_STATUS=" < "%TEMP%\supervooc_check.txt"
del "%TEMP%\supervooc_check.txt" >nul 2>&1

echo %FILE_STATUS% | findstr /i "EXISTS" >nul 2>&1
if %errorlevel% equ 0 (
    echo [!] The config file %MISSING_CONFIG% already exists on your device.
    echo [!] The fix may already be applied, or your firmware includes this file.
    echo.
    choice /c YN /n /m "[?] Back up the existing file as .bak? [Y/n]: "
    if !errorlevel!==1 (
        echo [*] Backing up...
        adb shell "cp '%FASTCHG_DIR%/%MISSING_CONFIG%' '/data/local/tmp/%MISSING_CONFIG%.bak'" 2>nul
        if !errorlevel! equ 0 (
            echo [+] Backup saved to /data/local/tmp/%MISSING_CONFIG%.bak
        ) else (
            echo [!] Could not back up ^(read-only filesystem^). The original is safe on the EROFS partition.
        )
    )
    echo.
    choice /c YN /n /m "[?] Continue with the fix anyway? [y/N]: "
    if !errorlevel!==2 (
        echo [*] Aborted. No changes were made.
        pause
        exit /b 0
    )
) else (
    echo [+] Confirmed: %MISSING_CONFIG% is missing ^(this is the bug^).
)

echo.
echo [*] Current contents of %FASTCHG_DIR%:
adb shell "ls -la %FASTCHG_DIR%" 2>nul

:: ----------------------------------------------------------------
echo.
echo === Step 4: Disable System Optimization ===
echo.
echo [*] Checking System Optimization setting...

for /f "tokens=*" %%a in ('adb shell settings get global oplus_customize_system_stable_plan_switch 2^>nul') do set "SYSOPT=%%a"

echo %SYSOPT% | findstr /i "1 null" >nul 2>&1
if %errorlevel% equ 0 (
    echo [!] System Optimization is enabled. This blocks Shizuku/TimerRoot permissions.
    echo [*] Disabling it now...
    adb shell settings put global oplus_customize_system_stable_plan_switch 0
    echo [+] System Optimization disabled.
    echo.
    echo [*] Note: on some ColorOS builds, this toggle is hidden in non-English languages.
    echo [*] If it re-enables itself, switch your phone to English, go to Developer Options,
    echo [*] disable 'System Optimization', then switch back.
) else (
    echo [+] System Optimization is already disabled.
)

:: ----------------------------------------------------------------
echo.
echo === Step 5: Push the fix script ===
echo.
echo [*] Pushing ksu_stage.sh to /data/local/tmp/...
adb push "%KSU_STAGE%" /data/local/tmp/ksu_stage.sh
if %errorlevel% neq 0 (
    echo [-] Failed to push ksu_stage.sh.
    pause
    exit /b 1
)
echo [+] Script pushed.

echo [*] Setting permissions to 444 (read-only)...
adb shell chmod 444 /data/local/tmp/ksu_stage.sh
echo [+] Permissions set. The exploit cannot overwrite the script.

:: ----------------------------------------------------------------
echo.
echo === Step 6: Check required apps ===
echo.

set "APPS_MISSING=0"

adb shell pm list packages 2>nul | findstr /i "kpgc10kai.timerroot" >nul 2>&1
if %errorlevel% equ 0 (
    echo [+] TimerRoot is installed.
) else (
    echo [!] TimerRoot is NOT installed.
    echo     Download it from: https://github.com/kpgc10kai/TimerRoot/releases
    set "APPS_MISSING=1"
)

adb shell pm list packages 2>nul | findstr /i "me.weishu.kernelsu" >nul 2>&1
if %errorlevel% equ 0 (
    echo [+] KernelSU is installed.
) else (
    echo [!] KernelSU is NOT installed.
    echo     Download it from: https://github.com/tiann/KernelSU/releases
    set "APPS_MISSING=1"
)

adb shell pm list packages 2>nul | findstr /i "moe.shizuku.privileged.api" >nul 2>&1
if %errorlevel% equ 0 (
    echo [+] Shizuku is installed.
) else (
    echo [!] Shizuku is NOT installed.
    echo     Download it from: https://github.com/RikkaApps/Shizuku/releases
    set "APPS_MISSING=1"
)

if "%APPS_MISSING%"=="1" (
    echo.
    echo [!] Install the missing apps above before continuing.
    echo.
    pause
)

:: ----------------------------------------------------------------
echo.
echo === Step 7: Start Shizuku ===
echo.
echo [*] Attempting to start Shizuku...

for /f "tokens=*" %%a in ('adb shell pm path moe.shizuku.privileged.api 2^>nul') do set "SHIZUKU_RAW=%%a"
set "SHIZUKU_APK=%SHIZUKU_RAW:package:=%"

if defined SHIZUKU_APK (
    if not "%SHIZUKU_APK%"=="" (
        start /b adb shell "app_process -Djava.class.path=%SHIZUKU_APK% /system/bin --nice-name=shizuku_server moe.shizuku.privileged.api.ShizukuService" >nul 2>&1
        timeout /t 2 /nobreak >nul
        echo [+] Shizuku server started.
        echo [*] Open the Shizuku app on your phone. It should show 'Running'.
    ) else (
        echo [!] Could not find Shizuku APK. Start it manually from the Shizuku app.
    )
) else (
    echo [!] Could not find Shizuku APK. Start it manually from the Shizuku app.
)

:: ----------------------------------------------------------------
echo.
echo === Step 8: Enable trace events ===
echo.
echo [*] Enabling kernel memory trace events...
adb shell "atrace --async_start -c -b 65536 memory" >nul 2>&1
echo [+] Trace events enabled.

:: ----------------------------------------------------------------
echo.
echo ============================================
echo   Setup complete
echo ============================================
echo.
echo To apply the fix after each reboot:
echo.
echo   1. Open TimerRoot on your phone
echo   2. Tap 'Get root shell'
echo   3. Wait for it to finish
echo.
echo If it fails (kernel panic, reboot, or 'selinux stage missed its race'),
echo just try again. It sometimes takes 2-3 attempts.
echo.
echo Once it succeeds, the fix is applied automatically.
echo You can verify by plugging in the charger: SUPERVOOC 80W should work.
echo.
echo To verify via ADB:
echo   adb shell "dumpsys battery | findstr voltage"
echo   10000 = SUPERVOOC (10V), 5000 = standard (5V)
echo.
echo [*] The fix is temporary. You need to run TimerRoot again after every reboot.
echo.
pause
