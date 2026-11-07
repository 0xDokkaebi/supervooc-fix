#!/system/bin/sh
# SUPERVOOC 80W fix + KernelSU late-load
# OnePlus 15R (CPH2769) ColorOS 17
# Missing config: silicon_x25_X2_single_charging_hyper_mode_config.txt

# --- SUPERVOOC fix (bind mount the missing config) ---
mkdir -p /data/local/tmp/fastchg_fix/24877
cp /odm/firmware/fastchg/24877/* /data/local/tmp/fastchg_fix/24877/
cp /data/local/tmp/fastchg_fix/24877/charging_hyper_mode_config.txt \
   /data/local/tmp/fastchg_fix/24877/silicon_x25_X2_single_charging_hyper_mode_config.txt
mount -o bind /data/local/tmp/fastchg_fix/24877 /odm/firmware/fastchg/24877

# --- KernelSU late-load ---
PKG=me.weishu.kernelsu
APK=$(pm path "$PKG" 2>/dev/null | head -1 | cut -d: -f2)
KSUD=
[ -n "$APK" ] && KSUD="$(dirname "$APK")/lib/arm64/libksud.so"
[ -x "$KSUD" ] || KSUD=$(find /data/app -path '*/me.weishu.kernelsu*/lib/arm64/libksud.so' 2>/dev/null | head -1)
[ -x "$KSUD" ] || KSUD=/data/local/tmp/ksud
[ -x "$KSUD" ] || KSUD=/data/adb/ksu/bin/ksud
if [ -x "$KSUD" ]; then
  "$KSUD" late-load --kmi android16-6.12 --allow-shell --package-name me.weishu.kernelsu
  i=0
  while [ $i -lt 50 ]; do
    grep -q '^kernelsu ' /proc/modules && break
    i=$((i+1)); sleep 0.1
  done
  grep -q '^kernelsu ' /proc/modules && echo KSU_LOADED || echo KSU_MISSING
else
  echo "[ksu] ksud not found"
fi
