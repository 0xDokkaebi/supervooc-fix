# SUPERVOOC 80W charging fix for OnePlus 15R

The OnePlus 15R (CPH2769) on ColorOS 17 stops SUPERVOOC charging at whatever battery level you plug it in at. If you start charging at 12%, it stops at around 13%. Plug it in at 84%, it stops at 85%. The charger drops from 10V to 5V and the phone trickle-charges from there. This fix gets fast charging working again across the full battery range.

This repo targets the **global version** (CPH2769, 6400mAh battery). The Chinese equivalent is the OnePlus Ace 6T. If your device has the same battery capacity and the same missing config file, this fix should apply. If your battery config is different, do not use this.

## What causes it

The OPLUS Charger HAL V12 service reads its charging profiles from `/odm/firmware/fastchg/24877/`. It expects a file called `silicon_x25_X2_single_charging_hyper_mode_config.txt` for single-battery SUPERVOOC mode. That file was never included in any firmware build (not ColorOS 17, not OxygenOS 16). Without it, the HAL falls back to a conservative charging profile that stops fast charging at the next percentage point after you plug in.

The parallel-mode config (`charging_hyper_mode_config.txt`) is present and contains the right thermal curves. The fix copies it under the missing filename and bind-mounts the directory over the read-only EROFS partition.

## Tested on

- **OnePlus 15R** (CPH2769, global, 6400mAh), ColorOS 17.0.0.106(EX01)
- Kernel `6.12.69-android16-6-g242e1a07f878-ab15865446-4k`

This was tested on the 15R specifically. The OnePlus 15 (CPH2747) has a different hardware configuration and may or may not have the same issue. If you try it on another device, check that the same config file is missing before applying the fix.

## Requirements

- [TimerRoot](https://github.com/kpgc10kai/TimerRoot) (temporary root via CVE-2026-98260)
- [KernelSU](https://github.com/tiann/KernelSU) manager app installed
- [Shizuku](https://github.com/RikkaApps/Shizuku) installed and running

## Setup (one time, via ADB)

### 1. Connect via USB or WiFi

USB:
```
adb devices
```

WiFi (from the phone's developer options, wireless debugging):
```
adb pair <IP>:<PAIRING_PORT> <CODE>
adb connect <IP>:<DEBUG_PORT>
```

If you connect through the phone's hotspot, the phone's IP is your default gateway, not the IP shown in the WiFi settings.

Linux/macOS:
```
ip route show dev wlan0 | grep default | awk '{print $3}'
```

Windows (PowerShell):
```powershell
(Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Where-Object { $_.InterfaceAlias -match "Wi-Fi" }).NextHop
```

Windows (cmd):
```
ipconfig | findstr "Default Gateway"
```

### 2. Disable System Optimization

ColorOS has a developer option called "System Optimization" that restricts Shizuku and ADB permissions for third-party apps. TimerRoot cannot get Shizuku access while this is enabled.

Via ADB:
```
adb shell settings put global oplus_customize_system_stable_plan_switch 0
```

If you prefer the UI toggle: on some ColorOS builds this option is hidden in non-English languages. Switch the phone language to English temporarily, go to Developer Options, disable "System Optimization", and switch back.

### 3. Push the fix script

```
adb push ksu_stage.sh /data/local/tmp/ksu_stage.sh
adb shell chmod 444 /data/local/tmp/ksu_stage.sh
```

The 444 permission is important. The exploit binary tries to overwrite `ksu_stage.sh` with its own default script before executing it. Making the file read-only prevents that, so our version (with the charging fix) runs instead.

### 4. Start Shizuku

Open the Shizuku app on the phone. If it stays stuck on "Waiting for service", start the server manually:

```
adb shell sh /storage/emulated/0/Android/data/moe.shizuku.privileged.api/start.sh
```

Or start it directly:

Linux/macOS:
```bash
SHIZUKU_APK=$(adb shell pm path moe.shizuku.privileged.api | head -1 | cut -d: -f2)
adb shell "app_process -Djava.class.path=$SHIZUKU_APK /system/bin --nice-name=shizuku_server moe.shizuku.privileged.api.ShizukuService"
```

Windows (PowerShell):
```powershell
$apk = (adb shell pm path moe.shizuku.privileged.api) -replace "package:",""
adb shell "app_process -Djava.class.path=$apk /system/bin --nice-name=shizuku_server moe.shizuku.privileged.api.ShizukuService"
```

### 5. Enable trace events

The exploit needs kernel memory trace events active. Run this before the first attempt after each reboot:
```
adb shell "atrace --async_start -c -b 65536 memory"
```

TimerRoot also does this through Shizuku, but running it manually from ADB is more reliable.

## Usage (phone only, after each reboot)

1. Open **TimerRoot**
2. Tap **Get root shell**
3. Wait for it to finish

If the first attempt fails ("selinux stage missed its race" or a kernel panic/reboot), try again. The exploit involves kernel race conditions and sometimes needs 2-3 attempts.

When it succeeds, `ksu_stage.sh` runs automatically with root privileges. It applies the SUPERVOOC bind mount fix and loads KernelSU via `ksud late-load`.

You can verify the fix is active:
```
adb shell ls /odm/firmware/fastchg/24877/
```
Both `charging_hyper_mode_config.txt` and `silicon_x25_X2_single_charging_hyper_mode_config.txt` should be listed.

To check charging voltage while plugged in:
```
adb shell dumpsys battery | grep "Charger voltage"
```
10000 = SUPERVOOC active (10V). 5000 = standard charging (5V).

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
Start the server manually via ADB (see step 4 above).

## Disclaimer

This fix involves a kernel exploit that temporarily modifies kernel memory. While the changes are cleared on reboot and nothing is written to the system partition, there is always some risk when running kernel exploits. Use at your own risk. The authors are not responsible for any damage, data loss, or other issues that may result from using this fix.

This was developed and tested on the OnePlus 15R (CPH2769, global, 6400mAh) only. Other devices (including the OnePlus 15) have different hardware and firmware. If your device does not have the same battery configuration, this fix may not apply or may cause unexpected behavior. Do not use this on a device with a different battery capacity.

## Related projects

- [TimerRoot](https://github.com/kpgc10kai/TimerRoot) - temporary root via kernel exploit
- [CVE-2026-98260](https://github.com/YuKongA/CVE-2026-98260) - the POSIX CPU timer exploit
- [KernelSU](https://github.com/tiann/KernelSU) - kernel-based root solution
- [Shizuku](https://github.com/RikkaApps/Shizuku) - shell-level access for apps without root

## License

MIT
