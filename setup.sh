#!/usr/bin/env bash
set -euo pipefail

DEVICE_MODEL="CPH2769"
DEVICE_NAME="OnePlus 15R"
MISSING_CONFIG="silicon_x25_X2_single_charging_hyper_mode_config.txt"
FASTCHG_DIR="/odm/firmware/fastchg/24877"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KSU_STAGE="$SCRIPT_DIR/ksu_stage.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { printf "${CYAN}[*]${NC} %s\n" "$1"; }
ok()    { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
fail()  { printf "${RED}[-]${NC} %s\n" "$1"; }
header(){ printf "\n${BOLD}=== %s ===${NC}\n\n" "$1"; }

abort() { fail "$1"; exit 1; }

ask_yn() {
    local prompt="$1" default="${2:-n}"
    while true; do
        if [ "$default" = "y" ]; then
            printf "${CYAN}[?]${NC} %s [Y/n] " "$prompt"
        else
            printf "${CYAN}[?]${NC} %s [y/N] " "$prompt"
        fi
        read -r answer
        answer="${answer:-$default}"
        case "$answer" in
            [yY]*) return 0 ;;
            [nN]*) return 1 ;;
        esac
    done
}

wait_enter() {
    printf "${CYAN}[>]${NC} %s" "${1:-Press Enter to continue...}"
    read -r
}

cleanup() {
    if [ "${CONNECTED:-0}" = "1" ] && [ "${CONN_METHOD:-}" = "wifi" ]; then
        adb disconnect "$DEVICE_ADDR" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# ----------------------------------------------------------------
header "SUPERVOOC 80W charging fix -- setup"
echo "This script sets up the SUPERVOOC charging fix on your $DEVICE_NAME ($DEVICE_MODEL)."
echo "It will connect to your phone via ADB, verify the device, and push the fix script."
echo ""

# check adb
if ! command -v adb >/dev/null 2>&1; then
    abort "adb not found. Install Android SDK Platform Tools first:
  - Arch/CachyOS: sudo pacman -S android-tools
  - Ubuntu/Debian: sudo apt install adb
  - macOS: brew install android-platform-tools
  - Or download from: https://developer.android.com/tools/releases/platform-tools"
fi
ok "adb found: $(command -v adb)"

# check ksu_stage.sh
if [ ! -f "$KSU_STAGE" ]; then
    abort "ksu_stage.sh not found next to this script. Make sure you run this from the repo directory."
fi
ok "ksu_stage.sh found"

# ----------------------------------------------------------------
header "Step 1: Connect to your phone"

echo "Make sure USB debugging (or Wireless debugging) is enabled on your phone:"
echo "  Settings > About phone > tap Build number 7 times"
echo "  Settings > System > Developer options > USB debugging (or Wireless debugging)"
echo ""

echo "How do you want to connect?"
echo "  1) USB cable"
echo "  2) WiFi (wireless debugging)"
echo ""
printf "${CYAN}[?]${NC} Choose [1/2]: "
read -r conn_choice

CONN_METHOD=""

case "$conn_choice" in
    1)
        CONN_METHOD="usb"
        echo ""
        info "Connect your phone via USB cable, then unlock it and tap 'Allow' on the USB debugging prompt."
        wait_enter "Press Enter when the phone is connected..."
        echo ""
        info "Waiting for device..."
        adb wait-for-device
        ok "Device connected via USB"
        ;;
    2)
        CONN_METHOD="wifi"
        echo ""
        info "On your phone, go to: Developer options > Wireless debugging > Pair device with pairing code"
        echo ""
        printf "${CYAN}[?]${NC} Enter the pairing port: "
        read -r pair_port
        printf "${CYAN}[?]${NC} Enter the pairing code: "
        read -r pair_code

        # figure out IP
        echo ""
        info "Detecting phone IP..."
        PHONE_IP=""

        # try gateway (if connected via phone hotspot)
        GW=$(ip route show dev wlan0 2>/dev/null | awk '/default/{print $3}' || true)
        if [ -z "$GW" ]; then
            # macOS
            GW=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}' || true)
        fi

        if [ -n "$GW" ]; then
            info "Detected gateway: $GW"
            if ask_yn "Is your PC connected to the phone's hotspot? (use $GW as phone IP)" "n"; then
                PHONE_IP="$GW"
            fi
        fi

        if [ -z "$PHONE_IP" ]; then
            printf "${CYAN}[?]${NC} Enter the phone's IP address (shown in Wireless debugging screen): "
            read -r PHONE_IP
        fi

        info "Pairing with $PHONE_IP:$pair_port..."
        adb pair "$PHONE_IP:$pair_port" "$pair_code" || abort "Pairing failed. Check the IP, port, and code."
        ok "Paired successfully"

        echo ""
        printf "${CYAN}[?]${NC} Enter the connection port (shown on the Wireless debugging main screen, NOT the pairing port): "
        read -r conn_port

        DEVICE_ADDR="$PHONE_IP:$conn_port"
        info "Connecting to $DEVICE_ADDR..."
        adb connect "$DEVICE_ADDR" || abort "Connection failed."
        CONNECTED=1
        ok "Connected via WiFi"
        ;;
    *)
        abort "Invalid choice."
        ;;
esac

# ----------------------------------------------------------------
header "Step 2: Verify device"

info "Checking device model..."
MODEL=$(adb shell getprop ro.build.product 2>/dev/null | tr -d '\r\n')
DISPLAY_MODEL=$(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r\n')

if [ "$MODEL" != "$DEVICE_MODEL" ] && [ "$DISPLAY_MODEL" != "$DEVICE_MODEL" ]; then
    fail "This device is '$DISPLAY_MODEL' ($MODEL), not $DEVICE_NAME ($DEVICE_MODEL)."
    fail "This fix is designed specifically for the $DEVICE_NAME. Using it on another device may cause issues."
    if ! ask_yn "Continue anyway? (NOT recommended)" "n"; then
        abort "Aborted. This fix is only for the $DEVICE_NAME ($DEVICE_MODEL)."
    fi
    warn "Proceeding at your own risk."
else
    ok "Device verified: $DISPLAY_MODEL ($MODEL)"
fi

# ----------------------------------------------------------------
header "Step 3: Check charging config"

info "Checking $FASTCHG_DIR for the missing config file..."

FILE_EXISTS=0
if adb shell "[ -f '$FASTCHG_DIR/$MISSING_CONFIG' ]" 2>/dev/null; then
    FILE_EXISTS=1
fi

if [ "$FILE_EXISTS" = "1" ]; then
    warn "The config file $MISSING_CONFIG already exists on your device."
    warn "The fix may already be applied, or your firmware includes this file."
    echo ""

    if ask_yn "Back up the existing file as .bak before overwriting?" "y"; then
        info "Backing up..."
        BACKUP_OK=0
        adb shell "cp '$FASTCHG_DIR/$MISSING_CONFIG' '/data/local/tmp/${MISSING_CONFIG}.bak'" 2>/dev/null && BACKUP_OK=1
        if [ "$BACKUP_OK" = "1" ]; then
            ok "Backup saved to /data/local/tmp/${MISSING_CONFIG}.bak"
        else
            warn "Could not back up (read-only filesystem). The file is on an EROFS partition, so the original is safe."
        fi
    fi

    if ! ask_yn "Continue with the fix anyway?" "n"; then
        info "Aborted. No changes were made."
        exit 0
    fi
else
    ok "Confirmed: $MISSING_CONFIG is missing (this is the bug)."
fi

# list existing configs for reference
echo ""
info "Current contents of $FASTCHG_DIR:"
adb shell "ls -la $FASTCHG_DIR" 2>/dev/null || warn "Could not list directory."

# ----------------------------------------------------------------
header "Step 4: Disable System Optimization"

info "Checking System Optimization setting..."
SYSOPT=$(adb shell settings get global oplus_customize_system_stable_plan_switch 2>/dev/null | tr -d '\r\n')

if [ "$SYSOPT" = "1" ] || [ "$SYSOPT" = "null" ]; then
    warn "System Optimization is enabled. This blocks Shizuku/TimerRoot permissions."
    info "Disabling it now..."
    adb shell settings put global oplus_customize_system_stable_plan_switch 0
    ok "System Optimization disabled."
    echo ""
    info "Note: on some ColorOS builds, this toggle is hidden in non-English languages."
    info "If it re-enables itself, switch your phone to English, go to Developer Options,"
    info "disable 'System Optimization', then switch back."
else
    ok "System Optimization is already disabled."
fi

# ----------------------------------------------------------------
header "Step 5: Push the fix script"

info "Pushing ksu_stage.sh to /data/local/tmp/..."
adb push "$KSU_STAGE" /data/local/tmp/ksu_stage.sh || abort "Failed to push ksu_stage.sh."
ok "Script pushed."

info "Setting permissions to 444 (read-only)..."
adb shell chmod 444 /data/local/tmp/ksu_stage.sh || abort "Failed to set permissions."
ok "Permissions set. The exploit cannot overwrite the script."

# ----------------------------------------------------------------
header "Step 6: Check required apps"

echo ""
APPS_MISSING=0

# TimerRoot
if adb shell pm list packages 2>/dev/null | grep -q "kpgc10kai.timerroot"; then
    ok "TimerRoot is installed."
else
    warn "TimerRoot is NOT installed."
    info "Download it from: https://github.com/kpgc10kai/TimerRoot/releases"
    APPS_MISSING=1
fi

# KernelSU
if adb shell pm list packages 2>/dev/null | grep -q "me.weishu.kernelsu"; then
    ok "KernelSU is installed."
else
    warn "KernelSU is NOT installed."
    info "Download it from: https://github.com/tiann/KernelSU/releases"
    APPS_MISSING=1
fi

# Shizuku
if adb shell pm list packages 2>/dev/null | grep -q "moe.shizuku.privileged.api"; then
    ok "Shizuku is installed."
else
    warn "Shizuku is NOT installed."
    info "Download it from: https://github.com/RikkaApps/Shizuku/releases"
    APPS_MISSING=1
fi

if [ "$APPS_MISSING" = "1" ]; then
    echo ""
    warn "Install the missing apps above before continuing."
    wait_enter "Press Enter once all apps are installed..."
fi

# ----------------------------------------------------------------
header "Step 7: Start Shizuku"

info "Attempting to start Shizuku..."
SHIZUKU_APK=$(adb shell pm path moe.shizuku.privileged.api 2>/dev/null | head -1 | cut -d: -f2 | tr -d '\r\n')

if [ -n "$SHIZUKU_APK" ]; then
    adb shell "app_process -Djava.class.path=$SHIZUKU_APK /system/bin --nice-name=shizuku_server moe.shizuku.privileged.api.ShizukuService" &
    SHIZUKU_PID=$!
    sleep 2
    ok "Shizuku server started."
    info "Open the Shizuku app on your phone. It should show 'Running'."
else
    warn "Could not find Shizuku APK. Start it manually from the Shizuku app."
fi

# ----------------------------------------------------------------
header "Step 8: Enable trace events"

info "Enabling kernel memory trace events..."
adb shell "atrace --async_start -c -b 65536 memory" >/dev/null 2>&1
ok "Trace events enabled."

# ----------------------------------------------------------------
header "Setup complete"

echo ""
printf "${GREEN}${BOLD}Everything is ready.${NC}\n"
echo ""
echo "To apply the fix after each reboot:"
echo ""
echo "  1. Open TimerRoot on your phone"
echo "  2. Tap 'Get root shell'"
echo "  3. Wait for it to finish"
echo ""
echo "If it fails (kernel panic, reboot, or 'selinux stage missed its race'),"
echo "just try again. It sometimes takes 2-3 attempts."
echo ""
echo "Once it succeeds, the fix is applied automatically."
echo "You can verify by plugging in the charger: SUPERVOOC 80W should work."
echo ""
echo "To verify via ADB:"
echo "  adb shell dumpsys battery | grep 'Charger voltage'"
echo "  10000 = SUPERVOOC (10V), 5000 = standard (5V)"
echo ""
info "The fix is temporary. You need to run TimerRoot again after every reboot."
echo ""
