# SUPERVOOC 80W charging fix for OnePlus 15R

The OnePlus 15R (CPH2769) on ColorOS 17 stops SUPERVOOC charging at whatever battery level you plug it in at. If you start charging at 12%, it stops at around 13%. Plug it in at 84%, it stops at 85%. The charger drops from 10V to 5V and the phone trickle-charges from there. This fix gets fast charging working again across the full battery range.

This repo targets the **global version** (CPH2769, 6400mAh battery). The Chinese equivalent is the OnePlus Ace 6T. If your device has the same battery capacity and the same missing config file, this fix should apply. If your battery config is different, do not use this.

## Table of contents

- [What causes it](#what-causes-it)
- [How I found the values](#how-i-found-the-values)
- [Disclaimer](#disclaimer)
- [Tested on](#tested-on)
- [Requirements](#requirements)
- [Setup on Windows](#setup-on-windows)
- [Setup on Linux / macOS](#setup-on-linux--macos)
- [Usage (phone only, after each reboot)](#usage-phone-only-after-each-reboot)
- [How the fix works](#how-the-fix-works)
- [Troubleshooting](#troubleshooting)
- [Related projects](#related-projects)

## What causes it

The OPLUS Charger HAL V12 service reads its charging profiles from `/odm/firmware/fastchg/24877/`. It expects a file called `silicon_x25_X2_single_charging_hyper_mode_config.txt` for single-battery SUPERVOOC mode. That file was never included in any firmware build (not ColorOS 17, not OxygenOS 16). Without it, the HAL falls back to a conservative charging profile that stops fast charging at the next percentage point after you plug in.

The parallel-mode config (`charging_hyper_mode_config.txt`) is present and contains the right thermal curves. The fix copies it under the missing filename and bind-mounts the directory over the read-only EROFS partition.

## How I found the values

### Identifying the missing config

The OPLUS Charger HAL V12 service logs its config loading sequence to logcat. When the phone is plugged in and fast charging fails, filtering logcat for `oplus_chg` and `fastchg` shows the HAL scanning `/odm/firmware/fastchg/24877/` for charging profiles. It successfully loads `charging_hyper_mode_config.txt` (parallel-mode) but fails to find `silicon_x25_X2_single_charging_hyper_mode_config.txt` (single-mode). The filename tells us exactly what the HAL expects: a Silicon X25 X2 single-cell charging config in hyper mode.

Listing the directory confirms it:
```
charging_hyper_mode_config.txt                              <-- present (parallel mode)
silicon_x25_X2_single_charging_hyper_mode_config.txt        <-- missing (single mode)
```

The HAL tries single-mode first. When the file is missing, it does not fall back to parallel-mode. Instead it falls back to a minimal safe profile that caps charging at the next percentage point.

### Why the parallel-mode config works as a replacement

Both configs describe thermal curves, voltage limits, and current profiles for the same battery and charging IC (Silicon X25 X2). The difference between "parallel" and "single" refers to the charging path topology, not the battery itself. On the 15R with its single 6400mAh cell, the HAL requests single-mode but the electrical parameters (max voltage, max current per step, thermal thresholds) are identical. The parallel-mode config contains the correct values for this hardware.

### Cross-validation with the OnePlus 13

To make sure the config values were not aberrant, I compared them against a known-working OnePlus 13 (same OPLUS Charger HAL generation). The 13 has both config files present and fast charging works out of the box. Comparing the thermal curves and voltage profiles between the two devices:

- **Voltage limits**: both devices use the same per-step voltage ceiling for their respective battery chemistries
- **Thermal thresholds**: the temperature cutoff points follow the same pattern (progressive current reduction at 35C, 40C, 45C), with the 15R's thresholds slightly more conservative due to its larger battery
- **Current profiles**: the max current values scale proportionally with battery capacity (the 15R's 6400mAh vs the 13's cell), confirming the curves are correctly calibrated for the hardware rather than being placeholder or debug values

This cross-check confirmed that the parallel-mode config on the 15R contains production-grade values that match the expected pattern for OPLUS fast charging, and that using it as the single-mode config does not push any parameter outside safe operating range.

## Disclaimer

This fix involves a kernel exploit that temporarily modifies kernel memory. While the changes are cleared on reboot and nothing is written to the system partition, there is always some risk when running kernel exploits. Use at your own risk. The authors are not responsible for any damage, data loss, or other issues that may result from using this fix.

This was developed and tested on the OnePlus 15R (CPH2769, global, 6400mAh) only. Other devices (including the OnePlus 15) have different hardware and firmware. If your device does not have the same battery configuration, this fix may not apply or may cause unexpected behavior. Do not use this on a device with a different battery capacity.

## Tested on

- **OnePlus 15R** (CPH2769, global, 6400mAh), ColorOS 17.0.0.106(EX01)
- Kernel `6.12.69-android16-6-g242e1a07f878-ab15865446-4k`

This was tested on the 15R specifically. The OnePlus 15 (CPH2747) has a different hardware configuration and may or may not have the same issue. If you try it on another device, check that the same config file is missing before applying the fix.

## Requirements

- [TimerRoot](https://github.com/kpgc10kai/TimerRoot) (temporary root via CVE-2026-98260)
- [KernelSU](https://github.com/tiann/KernelSU) manager app installed
- [Shizuku](https://github.com/RikkaApps/Shizuku) installed and running

---

## Setup on Windows

Everything below uses **PowerShell** unless noted otherwise. You need [Android SDK Platform Tools](https://developer.android.com/tools/releases/platform-tools) installed and `adb` in your PATH.

### 1. Connect to the phone

**USB:**
```powershell
adb devices
```

**WiFi** (from the phone's developer options, wireless debugging):
```powershell
adb pair <IP>:<PAIRING_PORT> <CODE>
adb connect <IP>:<DEBUG_PORT>
```

If you connect through the phone's hotspot, the phone's IP is your default gateway, not the IP shown in the WiFi settings. Find it with:

PowerShell:
```powershell
(Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Where-Object { $_.InterfaceAlias -match "Wi-Fi" }).NextHop
```

cmd:
```
ipconfig | findstr "Default Gateway"
```

### 2. Disable System Optimization

ColorOS has a developer option called "System Optimization" that restricts Shizuku and ADB permissions for third-party apps. TimerRoot cannot get Shizuku access while this is enabled.

```powershell
adb shell settings put global oplus_customize_system_stable_plan_switch 0
```

If you prefer the UI toggle: on some ColorOS builds this option is hidden in non-English languages. Switch the phone language to English temporarily, go to Developer Options, disable "System Optimization", and switch back.

### 3. Push the fix script

```powershell
adb push ksu_stage.sh /data/local/tmp/ksu_stage.sh
adb shell chmod 444 /data/local/tmp/ksu_stage.sh
```

The 444 permission is important. The exploit binary tries to overwrite `ksu_stage.sh` with its own default script before executing it. Making the file read-only prevents that, so our version (with the charging fix) runs instead.

### 4. Start Shizuku

Open the Shizuku app on the phone. If it stays stuck on "Waiting for service", start it from your PC:

```powershell
$apk = (adb shell pm path moe.shizuku.privileged.api) -replace "package:",""
adb shell "app_process -Djava.class.path=$apk /system/bin --nice-name=shizuku_server moe.shizuku.privileged.api.ShizukuService"
```

Or push the start script:
```powershell
adb shell sh /storage/emulated/0/Android/data/moe.shizuku.privileged.api/start.sh
```

### 5. Enable trace events

The exploit needs kernel memory trace events active. Run this before the first attempt after each reboot:
```powershell
adb shell "atrace --async_start -c -b 65536 memory"
```

TimerRoot also does this through Shizuku, but running it manually from ADB is more reliable.

### 6. Verify the fix

After TimerRoot succeeds (see [Usage](#usage-phone-only-after-each-reboot) below), check that both config files exist:
```powershell
adb shell ls /odm/firmware/fastchg/24877/
```
Both `charging_hyper_mode_config.txt` and `silicon_x25_X2_single_charging_hyper_mode_config.txt` should be listed.

Check charging voltage while plugged in:
```powershell
adb shell "dumpsys battery | findstr voltage"
```
10000 = SUPERVOOC active (10V). 5000 = standard charging (5V).

---

## Setup on Linux / macOS

### 1. Connect to the phone

**USB:**
```bash
adb devices
```

**WiFi** (from the phone's developer options, wireless debugging):
```bash
adb pair <IP>:<PAIRING_PORT> <CODE>
adb connect <IP>:<DEBUG_PORT>
```

If you connect through the phone's hotspot, the phone's IP is your default gateway, not the IP shown in the WiFi settings. Find it with:
```bash
ip route show dev wlan0 | grep default | awk '{print $3}'
```

On macOS, replace `wlan0` with `en0`, or use:
```bash
route -n get default | awk '/gateway:/{print $2}'
```

### 2. Disable System Optimization

ColorOS has a developer option called "System Optimization" that restricts Shizuku and ADB permissions for third-party apps. TimerRoot cannot get Shizuku access while this is enabled.

```bash
adb shell settings put global oplus_customize_system_stable_plan_switch 0
```

If you prefer the UI toggle: on some ColorOS builds this option is hidden in non-English languages. Switch the phone language to English temporarily, go to Developer Options, disable "System Optimization", and switch back.

### 3. Push the fix script

```bash
adb push ksu_stage.sh /data/local/tmp/ksu_stage.sh
adb shell chmod 444 /data/local/tmp/ksu_stage.sh
```

The 444 permission is important. The exploit binary tries to overwrite `ksu_stage.sh` with its own default script before executing it. Making the file read-only prevents that, so our version (with the charging fix) runs instead.

### 4. Start Shizuku

Open the Shizuku app on the phone. If it stays stuck on "Waiting for service", start it from your PC:

```bash
SHIZUKU_APK=$(adb shell pm path moe.shizuku.privileged.api | head -1 | cut -d: -f2)
adb shell "app_process -Djava.class.path=$SHIZUKU_APK /system/bin --nice-name=shizuku_server moe.shizuku.privileged.api.ShizukuService"
```

Or push the start script:
```bash
adb shell sh /storage/emulated/0/Android/data/moe.shizuku.privileged.api/start.sh
```

### 5. Enable trace events

The exploit needs kernel memory trace events active. Run this before the first attempt after each reboot:
```bash
adb shell "atrace --async_start -c -b 65536 memory"
```

TimerRoot also does this through Shizuku, but running it manually from ADB is more reliable.

### 6. Verify the fix

After TimerRoot succeeds (see [Usage](#usage-phone-only-after-each-reboot) below), check that both config files exist:
```bash
adb shell ls /odm/firmware/fastchg/24877/
```
Both `charging_hyper_mode_config.txt` and `silicon_x25_X2_single_charging_hyper_mode_config.txt` should be listed.

Check charging voltage while plugged in:
```bash
adb shell dumpsys battery | grep "Charger voltage"
```
10000 = SUPERVOOC active (10V). 5000 = standard charging (5V).

---

## Usage (phone only, after each reboot)

1. Open **TimerRoot**
2. Tap **Get root shell**
3. Wait for it to finish

If the first attempt fails ("selinux stage missed its race" or a kernel panic/reboot), try again. The exploit involves kernel race conditions and sometimes needs 2-3 attempts.

When it succeeds, `ksu_stage.sh` runs automatically with root privileges. It applies the SUPERVOOC bind mount fix and loads KernelSU via `ksud late-load`.

## How the fix works

1. The exploit (CVE-2026-98260, a POSIX CPU timer use-after-free) gives temporary root with full capabilities and disables SELinux
2. `ksu_stage.sh` copies the existing parallel-mode charging config as the missing single-mode config
3. A bind mount places the fixed directory over the EROFS read-only partition at `/odm/firmware/fastchg/24877/`
4. The Charger HAL picks up the config on its next read and enables SUPERVOOC at full power
5. KernelSU is loaded for additional root management

The fix is temporary. A reboot clears the bind mount and the exploit's kernel modifications. Nothing is written to the system partition.

## Troubleshooting

**TimerRoot shows "ADB permission is limited"**
Run the System Optimization disable command from step 2. On some ColorOS builds, the toggle is hidden in non-English languages.

**Exploit fails with "page event ids not found"**
Trace events are not enabled. Run `atrace --async_start -c -b 65536 memory` via ADB.

**Exploit causes a reboot**
This happens occasionally. The kernel exploit involves race conditions that can trigger a panic. The phone boots normally afterward. Just retry.

**KernelSU says "jailbreak failed"**
Reboot and try again. Do not attempt a second run without rebooting first, as the parked exploit process from the first run interferes.

**Shizuku stuck on "Waiting for service"**
Start the server manually via ADB (see step 4 in your OS section above).

## Related projects

- [TimerRoot](https://github.com/kpgc10kai/TimerRoot) - temporary root via kernel exploit
- [CVE-2026-98260](https://github.com/YuKongA/CVE-2026-98260) - the POSIX CPU timer exploit
- [KernelSU](https://github.com/tiann/KernelSU) - kernel-based root solution
- [Shizuku](https://github.com/RikkaApps/Shizuku) - shell-level access for apps without root

## License

MIT
