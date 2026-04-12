#!/bin/bash
# sample-sysst.sh — Passive AW88298 sampler for an L/R audio test
#
# Reads SYSST, PVDD, VBAT, TEMP, ISNDAT, and VSNDAT in a tight loop and
# only prints when something changes, so transients are not drowned out
# by thousands of identical lines. NEVER touches SYSINT (read-clear).
#
# Usage:
#   sudo ./sample-sysst.sh                # run until Ctrl+C
#   sudo ./sample-sysst.sh 30             # run for 30 seconds and exit
#
# Before launching:
#   - Stop the daemon:   sudo systemctl stop aw88298
#   - Leave the chip powered on with a stable config (the daemon will
#     have left it configured if you just stopped it)
#   - Start an L/R test loop (the usual stereo test video works)
#
# Output format (one line per change):
#   HH:MM:SS.mmm  SYSST=0xXXXX [PLLS CLKS WDS BSTS ...]  PVDD=X.XXV  VBAT=X.XXV  TEMP=XX  ISN=0xXXXX  VSN=0xXXXX
#
# Copyright (C) 2026 Francisco Montañés García <fco.gmon@gmail.com>

set -u

I2C_BUS=0
I2C_ADDR=0x34
I2CGET=/usr/bin/i2cget

DURATION="${1:-0}"          # 0 = run forever
START_NS=$(date +%s%N)

# i2cget -w returns 16 bits in little-endian; the chip stores them in
# big-endian. Byteswap to show a human-readable value.
read_be() {
    local reg="$1"
    local raw
    raw=$($I2CGET -y $I2C_BUS $I2C_ADDR "$reg" w 2>/dev/null) || return 1
    raw=${raw#0x}
    # raw is 4 hex chars little-endian: "LLHH" => BE "HHLL"
    local lo="${raw:0:2}"
    local hi="${raw:2:2}"
    printf "0x%s%s" "$hi" "$lo"
}

# Decode SYSST bits into a readable label
decode_sysst() {
    local v=$1
    local tags=""
    (( v & 0x001 )) && tags="$tags PLLS"
    (( v & 0x002 )) && tags="$tags OTHS"
    (( v & 0x004 )) && tags="$tags OTLS"
    (( v & 0x008 )) && tags="$tags OCDS"
    (( v & 0x010 )) && tags="$tags CLKS"
    (( v & 0x020 )) && tags="$tags NOCLKS!"
    (( v & 0x100 )) && tags="$tags WDS"
    (( v & 0x200 )) && tags="$tags BSTS"
    echo "${tags# }"
}

# VBAT / PVDD / TEMP are raw readings — scale where relevant.
# From the mainline aw882xx driver: PVDD = raw * 6 * 1000 / 1023 (mV);
# VBAT = raw * 6 * 1000 / 1023 (mV); TEMP = raw (signed 10-bit, °C).
scale_mv() {
    local raw=$1
    # raw is "0xXXXX" hex
    local v=$(( raw ))
    echo $(( v * 6 * 1000 / 1023 ))
}

ts() {
    local now_ns=$(date +%s%N)
    local elapsed_ms=$(( (now_ns - START_NS) / 1000000 ))
    printf "%02d:%02d.%03d" $((elapsed_ms/60000)) $(((elapsed_ms/1000)%60)) $((elapsed_ms%1000))
}

echo "[$(date +%H:%M:%S)] Sampling AW88298 (printing SYSST diffs only). Ctrl+C to exit."
echo "Header: T+mm:ss.mmm  SYSST=hex [flags]  PVDD=mV  VBAT=mV  TEMP=raw  ISN=hex  VSN=hex"
echo

prev=""
n_samples=0
n_changes=0

trap 'echo; echo "Samples: $n_samples, changes: $n_changes"; exit 0' INT TERM

while true; do
    sysst=$(read_be 0x01) || { sleep 0.01; continue; }
    pvdd=$(read_be 0x14)  || pvdd="0x0"
    vbat=$(read_be 0x12)  || vbat="0x0"
    temp=$(read_be 0x13)  || temp="0x0"
    isn=$(read_be 0x15)   || isn="0x0"
    vsn=$(read_be 0x16)   || vsn="0x0"

    sig="$sysst|$pvdd|$vbat|$temp|$isn|$vsn"
    n_samples=$((n_samples+1))

    if [[ "$sig" != "$prev" ]]; then
        n_changes=$((n_changes+1))
        flags=$(decode_sysst "$sysst")
        pvdd_mv=$(scale_mv "$pvdd")
        vbat_mv=$(scale_mv "$vbat")
        temp_raw=$(( temp ))
        printf "T+%s  SYSST=%s [%s]  PVDD=%dmV  VBAT=%dmV  TEMP=%d  ISN=%s  VSN=%s\n" \
            "$(ts)" "$sysst" "$flags" "$pvdd_mv" "$vbat_mv" "$temp_raw" "$isn" "$vsn"
        prev="$sig"
    fi

    # No sleep: poll as fast as possible (I2C at 100 kHz limits the rate anyway)

    if (( DURATION > 0 )); then
        now_ns=$(date +%s%N)
        elapsed_s=$(( (now_ns - START_NS) / 1000000000 ))
        (( elapsed_s >= DURATION )) && break
    fi
done

echo
echo "Samples: $n_samples, changes: $n_changes"
