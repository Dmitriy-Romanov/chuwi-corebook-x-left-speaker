#!/bin/bash
# aw88298-daemon.sh — Keep the Chuwi CoreBook X left speaker alive
#
# Watches the HDA stream on the Conexant SN6180 and drives the AWINIC
# AW88298 smart PA behind pin 0x1d so the left speaker plays in sync
# with the right one. Re-applies the stream mirror whenever PipeWire
# reassigns the stream, mirrors the system volume slider to the left
# DAC, and propagates mute events from the HDA layer (e.g. headphone
# plug) to the AW88298.
#
# Usage:
#   sudo ./aw88298-daemon.sh           # foreground
#   sudo ./aw88298-daemon.sh &         # background
#   sudo systemctl start aw88298       # as a systemd service
#
# Copyright (C) 2026 Francisco Montañés García <fco.gmon@gmail.com>

HDA_DEV="/dev/snd/hwC1D0"
I2C_BUS=0
I2C_ADDR=0x34
POLL_INTERVAL=1  # seconds (>1s to stay out of the audio path)

# Volume mirror: DAC 0x22 amp = max(0, DAC 0x11 amp - VOL_OFFSET)
# Calibrated 2026-04-12 with Force Boost + INPLEV=0dB: DAC 0x11=0x4a <=> DAC 0x22=0x40
VOL_OFFSET=10
LAST_VOL="-1"

# Absolute paths (required when running under systemd)
HDAVERB=hda-verb
I2CSET=i2cset
I2CGET=i2cget

LAST_STREAM="0x0"
LAST_FORMAT="0x0"
AMP_ON=false

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Read a 16-bit register from the AW88298 and return the value in
# big-endian form (the chip stores them as BE but i2cget returns LE
# over the SMBus word transaction). Prints the hex digits with no
# "0x" prefix, or nothing on failure.
read_reg_be() {
    local reg="$1"
    local raw
    raw=$($I2CGET -y $I2C_BUS $I2C_ADDR "$reg" w 2>/dev/null) || return 1
    raw=${raw#0x}
    local lo="${raw:0:2}"
    local hi="${raw:2:2}"
    printf "%s%s" "$hi" "$lo"
}

# Force BST_MODE=001 (Force Boost) in BSTCTRL2 (0x61) while preserving
# BST_TDEG (bits 10:8) and VOUT_VREFSET (bits 5:0). The chip powers up
# in Smart Boost 2 (bits 14:12 = 110), which idles the boost converter
# during digital silence and causes ~100-200 ms glitches at the start
# of every sound event. Force Boost eliminates those glitches.
# Verified with the SYSST sampler 2026-04-12.
force_boost() {
    local be new_be lo hi le
    be=$(read_reg_be 0x61) || { log "force_boost: failed to read 0x61"; return 1; }
    # Clear bits 14:12, set bit 12 (BST_MODE = 001, Force Boost)
    new_be=$(( (0x$be & 0x8FFF) | 0x1000 ))
    # Convert BE -> LE for i2cset
    hi=$(( (new_be >> 8) & 0xFF ))
    lo=$(( new_be & 0xFF ))
    le=$(printf "0x%02x%02x" $lo $hi)
    $I2CSET -y $I2C_BUS $I2C_ADDR 0x61 "$le" w 2>/dev/null
    log "BSTCTRL2: 0x$be -> $(printf "0x%04x" $new_be) BE (Force Boost)"
}

hda_power_cycle() {
    # After suspend/resume, DAC 0x22 and pin 0x1d end up in an internal
    # state where their verbs still report sensible values but no audio
    # flows through the I2S link. Forcing D3 -> D0 wakes the SN6180's
    # internal I2S link back up. Discovered empirically on 2026-04-12.
    $HDAVERB $HDA_DEV 0x1d 0x705 0x3 > /dev/null 2>&1
    $HDAVERB $HDA_DEV 0x22 0x705 0x3 > /dev/null 2>&1
    sleep 0.05
    $HDAVERB $HDA_DEV 0x22 0x705 0x0 > /dev/null 2>&1
    $HDAVERB $HDA_DEV 0x1d 0x705 0x0 > /dev/null 2>&1
    sleep 0.02
    log "HDA power cycle: DAC 0x22 and pin 0x1d forced D3->D0"
}

setup_amp() {
    # Power-cycle the HDA side in case we are coming back from suspend
    # (no-op at cold start).
    hda_power_cycle
    # Power on the AW88298 — final stable configuration.
    # Step 1: power on at AV10 with I2SEN off (reduces boost stress)
    $I2CSET -y $I2C_BUS $I2C_ADDR 0x04 0x0020 w 2>/dev/null
    sleep 0.003
    # Step 2: SPK_GAIN=7 (max) + I2SEN  (BE 0x7040 -> LE 0x4070)
    $I2CSET -y $I2C_BUS $I2C_ADDR 0x04 0x4070 w 2>/dev/null
    sleep 0.002
    # SYSCTRL2: HAGCE=1, BST_IPEAK=11, HMUTE=0
    $I2CSET -y $I2C_BUS $I2C_ADDR 0x05 0x6B00 w 2>/dev/null
    # I2SCTRL: INPLEV=0 dB (BE 0x14E8 -> LE 0xE814), no input attenuation.
    # With Force Boost there is no clipping from boost dropout, so the
    # -6 dB headroom we used under Smart Boost 2 is no longer needed.
    $I2CSET -y $I2C_BUS $I2C_ADDR 0x06 0xE814 w 2>/dev/null
    # Raised HAGC thresholds (less AGC intervention, higher average level)
    $I2CSET -y $I2C_BUS $I2C_ADDR 0x09 0x4079 w 2>/dev/null  # HAGCCFG1
    $I2CSET -y $I2C_BUS $I2C_ADDR 0x0A 0x7000 w 2>/dev/null  # HAGCCFG2
    # Pin 0x1d: output + EAPD
    $HDAVERB $HDA_DEV 0x1d 0x707 0x40 > /dev/null 2>&1
    $HDAVERB $HDA_DEV 0x1d 0x70c 0x02 > /dev/null 2>&1
    # BSTCTRL2: force BST_MODE=001 (Force Boost) — eliminates the
    # startup glitches caused by Smart Boost 2 idling the converter
    # during digital silence. RMW preserves BST_TDEG and VOUT_VREFSET.
    force_boost
    AMP_ON=true

    # Re-apply the stream mirror and volume in case hda_power_cycle
    # disturbed the converters' channel/format. Force LAST_* so that
    # the main loop re-verifies on the next iteration as well.
    local cur_stream
    cur_stream=$($HDAVERB $HDA_DEV 0x11 0xf06 0 2>/dev/null | grep "value" | awk '{print $NF}')
    if [[ "$cur_stream" != "0x0" && -n "$cur_stream" ]]; then
        apply_stream "$cur_stream"
        mirror_volume
    fi
}

shutdown_amp() {
    $I2CSET -y $I2C_BUS $I2C_ADDR 0x05 0x3800 w 2>/dev/null  # HMUTE
    sleep 0.001
    $I2CSET -y $I2C_BUS $I2C_ADDR 0x04 0x0340 w 2>/dev/null  # PWDN+AMPPD
    $HDAVERB $HDA_DEV 0x22 0x706 0x00 > /dev/null 2>&1
    AMP_ON=false
}

apply_stream() {
    local stream_raw="$1"
    local stream_id=$(( ($stream_raw >> 4) & 0xF ))
    local stream_r=$(printf "0x%x" $(( (stream_id << 4) | 1 )))
    local stream_l=$(printf "0x%x" $(( (stream_id << 4) | 0 )))

    # Format
    local format=$($HDAVERB $HDA_DEV 0x11 0xa00 0 2>/dev/null | grep "value" | awk '{print $NF}')

    # DAC 0x11 -> right channel, DAC 0x22 -> left channel
    $HDAVERB $HDA_DEV 0x11 0x706 "$stream_r" > /dev/null 2>&1
    $HDAVERB $HDA_DEV 0x22 0x706 "$stream_l" > /dev/null 2>&1
    $HDAVERB $HDA_DEV 0x22 0x200 "$format" > /dev/null 2>&1
    # DAC 0x11 amp is left untouched — the ALSA mixer owns it.
    # DAC 0x22 amp is kept in sync by mirror_volume().
    LAST_VOL="-1"  # force re-application of the mirror after a stream change

    log "Stream $stream_id: DAC 0x11=$stream_r(R) DAC 0x22=$stream_l(L) fmt=$format"
}

# Sync the DAC 0x22 amp with the DAC 0x11 amp, applying a calibrated
# offset. Runs on every tick of the main loop so it tracks the slider.
# Honors bit 7 (MUTE) of the DAC 0x11 amp so that plugging in
# headphones (PipeWire mutes DAC 0x11 -> 0x80) also mutes the left
# speaker.
mirror_volume() {
    local vol_11
    vol_11=$($HDAVERB $HDA_DEV 0x11 0xb00 0x8000 2>/dev/null | grep "value" | awk '{print $NF}')
    [[ -z "$vol_11" ]] && return
    local v11=$(( vol_11 ))
    local muted=$(( v11 & 0x80 ))
    local gain=$(( v11 & 0x7f ))
    local v22 sig
    if (( muted )); then
        v22=0
        sig="muted"
    else
        v22=$(( gain - VOL_OFFSET ))
        (( v22 < 0 )) && v22=0
        (( v22 > 0x4a )) && v22=0x4a
        sig="$v22"
    fi
    if [[ "$sig" != "$LAST_VOL" ]]; then
        if (( muted )); then
            # 0xb080 = output L+R, mute=1, gain=0
            $HDAVERB $HDA_DEV 0x22 0x300 0xb080 > /dev/null 2>&1
            $HDAVERB $HDA_DEV 0x22 0x300 0x9080 > /dev/null 2>&1
            log "Vol mirror: DAC 0x11=0x$(printf "%02x" $v11) [MUTED] -> DAC 0x22 muted"
        else
            $HDAVERB $HDA_DEV 0x22 0x300 $(printf "0xb0%02x" $v22) > /dev/null 2>&1
            $HDAVERB $HDA_DEV 0x22 0x300 $(printf "0x90%02x" $v22) > /dev/null 2>&1
            log "Vol mirror: DAC 0x11=0x$(printf "%02x" $v11) -> DAC 0x22=0x$(printf "%02x" $v22)"
        fi
        LAST_VOL="$sig"
    fi
}

cleanup() {
    log "Shutting down..."
    shutdown_amp
    # Restore DAC 0x11 to channel 0
    local s=$($HDAVERB $HDA_DEV 0x11 0xf06 0 2>/dev/null | grep "value" | awk '{print $NF}')
    local sid=$(( ($s >> 4) & 0xF ))
    $HDAVERB $HDA_DEV 0x11 0x706 $(printf "0x%x" $((sid << 4))) > /dev/null 2>&1
    log "Restored"
    exit 0
}

trap cleanup SIGINT SIGTERM

log "AW88298 daemon started (poll=${POLL_INTERVAL}s)"
setup_amp

while true; do
    # Read the current DAC 0x11 stream
    STREAM=$($HDAVERB $HDA_DEV 0x11 0xf06 0 2>/dev/null | grep "value" | awk '{print $NF}')

    if [[ "$STREAM" != "$LAST_STREAM" ]]; then
        if [[ "$STREAM" == "0x0" ]]; then
            log "Stream stopped"
        else
            # New stream or stream reassigned by PipeWire
            apply_stream "$STREAM"
            if ! $AMP_ON; then
                setup_amp
            fi
        fi
        LAST_STREAM="$STREAM"
    fi

    # Verify DAC 0x11 is still on channel R and the formats match
    if [[ "$STREAM" != "0x0" ]]; then
        CURRENT=$($HDAVERB $HDA_DEV 0x11 0xf06 0 2>/dev/null | grep "value" | awk '{print $NF}')
        EXPECTED_R=$(printf "0x%x" $(( ((($CURRENT >> 4) & 0xF) << 4) | 1 )))
        FMT_11=$($HDAVERB $HDA_DEV 0x11 0xa00 0 2>/dev/null | grep "value" | awk '{print $NF}')
        FMT_22=$($HDAVERB $HDA_DEV 0x22 0xa00 0 2>/dev/null | grep "value" | awk '{print $NF}')
        if [[ "$CURRENT" != "$EXPECTED_R" || "$FMT_11" != "$FMT_22" ]]; then
            apply_stream "$CURRENT"
        fi

        # Check that the AW88298 is still powered on (it may power
        # itself down after suspend)
        AMP_ST=$($I2CGET -y $I2C_BUS $I2C_ADDR 0x04 w 2>/dev/null)
        if [[ "$AMP_ST" == "0x0340" || "$AMP_ST" == "0x0300" || "$AMP_ST" == "0x0540" ]]; then
            log "AW88298 powered down, bringing it back up..."
            setup_amp
        fi

        # Check that BSTCTRL2 is still in Force Boost (bits[14:12]=001)
        BST=$(read_reg_be 0x61)
        if [[ -n "$BST" ]]; then
            BST_MODE=$(( (0x$BST >> 12) & 0x7 ))
            if (( BST_MODE != 1 )); then
                log "BSTCTRL2 drifted out of Force Boost (0x$BST), re-applying"
                force_boost
            fi
        fi

        # Sync the left speaker volume with the right-slider amp
        mirror_volume
    fi

    sleep $POLL_INTERVAL
done
