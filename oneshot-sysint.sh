#!/bin/bash
# oneshot-sysint.sh — Single-shot SYSINT (read-clear) reader for the AW88298
#
# SYSINT (0x02) is a read-clear register: reading it wipes the history.
# That is why it is NOT polled like SYSST. This script does a single
# read, decodes the flags, and exits.
#
# Suggested usage:
#   1. Wait for the exact moment you want to capture (e.g. right after
#      returning to "Left" during an L/R test, after a few seconds of
#      "Right").
#   2. sudo ./oneshot-sysint.sh
#
# Copyright (C) 2026 Francisco Montañés García <fco.gmon@gmail.com>

set -u

I2C_BUS=0
I2C_ADDR=0x34
I2CGET=i2cget

raw=$($I2CGET -y $I2C_BUS $I2C_ADDR 0x02 w 2>/dev/null) || {
    echo "ERROR: failed to read SYSINT" >&2
    exit 1
}

# Byteswap LE -> BE
raw=${raw#0x}
lo="${raw:0:2}"
hi="${raw:2:2}"
sysint=$(( 0x$hi$lo ))

echo "[$(date +%H:%M:%S.%3N)] SYSINT = 0x$(printf "%04x" $sysint)"
echo

tags=""
# Bits from the aw882xx PID 1852 datasheet (same offsets as SYSST for the *S -> *IS):
(( sysint & 0x0001 )) && tags="$tags PLLIS"       # PLL lock event
(( sysint & 0x0002 )) && tags="$tags OTHIS"       # Over-temp high
(( sysint & 0x0004 )) && tags="$tags OTLIS"       # Over-temp low
(( sysint & 0x0008 )) && tags="$tags OCDIS"       # Over-current
(( sysint & 0x0010 )) && tags="$tags CLKIS"       # Clock event
(( sysint & 0x0020 )) && tags="$tags NOCLKIS!"    # No clock
(( sysint & 0x0040 )) && tags="$tags CLIP_PREIS"  # Clipping pre
(( sysint & 0x0080 )) && tags="$tags CLIPIS"      # Clipping
(( sysint & 0x0100 )) && tags="$tags WDIS"        # Watchdog
(( sysint & 0x0200 )) && tags="$tags BSTIS"       # Boost event
(( sysint & 0x0400 )) && tags="$tags BSTOCIS!"    # Boost over-current
(( sysint & 0x0800 )) && tags="$tags OVPIS"       # Over-voltage
(( sysint & 0x1000 )) && tags="$tags UVLIS"       # Under-voltage lockout
(( sysint & 0x2000 )) && tags="$tags DSPIS"       # DSP event
(( sysint & 0x4000 )) && tags="$tags BSTSCIS"     # Boost short-circuit
(( sysint & 0x8000 )) && tags="$tags TEMPIS"      # Temperature event

if [[ -z "$tags" ]]; then
    echo "Flags: none (chip clean)"
else
    echo "Flags:$tags"
fi
