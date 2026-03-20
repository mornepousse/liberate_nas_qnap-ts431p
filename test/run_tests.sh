#!/bin/bash
# QNAP TS-431P Debian system test suite — run on target NAS
# Usage: bash run_tests.sh [gateway_ip]

set -u
GW="${1:-192.168.1.1}"
IFACE="enp0s1"
PASS=0
FAIL=0
WARN=0

pass() { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN+1)); }

echo "========================================"
echo " QNAP TS-431P system test suite"
echo " $(date)"
echo "========================================"
echo

# -----------------------------------------------
echo "--- 1. Kernel ---"
KVER=$(uname -r)
ARCH=$(uname -m)
pass "Kernel: $KVER ($ARCH)"
echo

# -----------------------------------------------
echo "--- 2. Out-of-tree drivers ---"
for MOD in al_eth al_thermal al_nand; do
    if lsmod | grep -q "$MOD"; then
        pass "$MOD loaded"
    else
        fail "$MOD NOT loaded"
    fi
done
echo

# -----------------------------------------------
echo "--- 3. Network ---"
STATE=$(ip link show "$IFACE" 2>/dev/null | grep -o "state [A-Z]*" | awk '{print $2}')
IPV4=$(ip -4 addr show "$IFACE" 2>/dev/null | grep -oP 'inet \K[0-9./]+')
if [ "$STATE" = "UP" ] && [ -n "$IPV4" ]; then
    pass "$IFACE: UP, $IPV4"
else
    fail "$IFACE: state=${STATE:-missing} ip=${IPV4:-none}"
fi

if ping -c2 -W2 "$GW" &>/dev/null; then
    pass "Gateway $GW reachable"
else
    fail "Cannot reach gateway $GW"
fi

if command -v ethtool &>/dev/null; then
    SPEED=$(ethtool "$IFACE" 2>/dev/null | grep "Speed:" | awk '{print $2}')
    [ -n "$SPEED" ] && pass "Link: $SPEED" || warn "Cannot read speed"
fi
echo

# -----------------------------------------------
echo "--- 4. Disks & RAID ---"
DISK_COUNT=$(lsblk -d -n -o NAME,TYPE 2>/dev/null | grep disk | wc -l)
pass "$DISK_COUNT disk(s) detected"

if [ -e /proc/mdstat ]; then
    while read line; do
        DEV=$(echo "$line" | awk '{print $1}')
        STATE=$(grep -A1 "^$DEV" /proc/mdstat | tail -1 | grep -oP '\[.*\]' | tail -1)
        if echo "$STATE" | grep -q "_"; then
            fail "$DEV: degraded $STATE"
        else
            pass "$DEV: healthy $STATE"
        fi
    done < <(grep "^md" /proc/mdstat)
fi
echo

# -----------------------------------------------
echo "--- 5. Services ---"
for SVC in sshd smbd chronyd; do
    if systemctl is-active "$SVC" &>/dev/null; then
        pass "$SVC: active"
    else
        warn "$SVC: not active"
    fi
done
echo

# -----------------------------------------------
echo "--- 6. Temperature ---"
if lsmod | grep -q al_thermal; then
    for tz in /sys/class/thermal/thermal_zone*/temp; do
        [ -f "$tz" ] || continue
        TEMP=$(($(cat "$tz") / 1000))
        pass "SoC: ${TEMP}°C"
    done
fi
for h in /sys/class/hwmon/hwmon*/; do
    NAME=$(cat "${h}name" 2>/dev/null)
    TEMP_F=$(ls "${h}"temp*_input 2>/dev/null | head -1)
    if [ -n "$TEMP_F" ]; then
        T=$(($(cat "$TEMP_F") / 1000))
        echo "       hwmon $NAME: ${T}°C"
    fi
done
echo

# -----------------------------------------------
echo "--- 7. NAND (MTD) ---"
if [ -e /proc/mtd ]; then
    MTD_COUNT=$(grep -c "mtd" /proc/mtd)
    pass "$MTD_COUNT MTD partitions"
else
    warn "No /proc/mtd"
fi
echo

# -----------------------------------------------
echo "--- 8. RTC ---"
if command -v hwclock &>/dev/null; then
    HW_TIME=$(hwclock -r 2>/dev/null)
    if [ -n "$HW_TIME" ]; then
        pass "RTC: $HW_TIME"
    else
        warn "Cannot read RTC"
    fi
fi
echo

# -----------------------------------------------
echo "--- 9. Memory & Swap ---"
MEM_MB=$(($(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024))
AVAIL_MB=$(($(grep MemAvailable /proc/meminfo | awk '{print $2}') / 1024))
pass "RAM: ${AVAIL_MB}MB free / ${MEM_MB}MB total"
SWAP_MB=$(($(grep SwapTotal /proc/meminfo | awk '{print $2}') / 1024))
if [ "$SWAP_MB" -gt 0 ]; then
    pass "Swap: ${SWAP_MB}MB"
else
    warn "No swap"
fi
echo

# -----------------------------------------------
echo "--- 10. Interrupts ---"
IRQ_LINES=$(grep al-eth /proc/interrupts 2>/dev/null)
if [ -n "$IRQ_LINES" ]; then
    QUEUES=$(echo "$IRQ_LINES" | grep -c "rx-comp")
    pass "al_eth MSI-X: $QUEUES RX queues"
else
    warn "No al-eth interrupts"
fi
echo

# -----------------------------------------------
echo "--- 11. Firewall ---"
if command -v nft &>/dev/null; then
    POLICY=$(nft list chain inet filter input 2>/dev/null | grep "policy" | grep -o "accept\|drop")
    if [ "$POLICY" = "accept" ]; then
        pass "nftables: policy accept"
    elif [ "$POLICY" = "drop" ]; then
        warn "nftables: policy drop (may block services)"
    else
        pass "nftables: no restrictive rules"
    fi
fi
echo

# -----------------------------------------------
echo "--- 12. SMART ---"
if command -v smartctl &>/dev/null; then
    OK=0
    for dev in /dev/sd[a-z]; do
        [ -b "$dev" ] || continue
        H=$(smartctl -H "$dev" 2>/dev/null | grep "SMART overall" | awk '{print $NF}')
        [ "$H" = "PASSED" ] && OK=$((OK+1))
    done
    [ "$OK" -gt 0 ] && pass "SMART: $OK disk(s) healthy"
fi
echo

# -----------------------------------------------
echo "--- 13. dmesg ---"
ERRS=$(dmesg 2>/dev/null | grep -iE "error|fail|oops|panic|bug" | grep -viE "corrected|non-fatal|PCIe|of_irq_parse|failed to come online" | tail -5)
if [ -z "$ERRS" ]; then
    pass "No critical errors in dmesg"
else
    warn "Possible errors in dmesg:"
    echo "$ERRS" | while read l; do echo "       $l"; done
fi
echo

# -----------------------------------------------
echo "========================================"
echo " Results: $PASS PASS, $FAIL FAIL, $WARN WARN"
echo "========================================"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
