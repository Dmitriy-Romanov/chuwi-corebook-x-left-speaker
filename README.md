# Chuwi CoreBook X — Left speaker workaround for Linux

A userspace daemon that enables the left speaker on the Chuwi CoreBook X
laptop under Linux. Both speakers work, stereo is correct, the system
volume slider moves both together, and plugging in headphones mutes both
correctly.

## The problem

On the Chuwi CoreBook X (AMD Ryzen 5 7430U, Conexant SN6180 HDA codec), only
the right speaker works out of the box on Linux. The left speaker is driven
by an **AWINIC AW88298** Smart PA chip, connected to the codec over I2C (for
control) and I2S (for audio data) through an undocumented I2S output on the
SN6180 HDA codec. There is no mainline Linux driver for the AW88298 on an
HDA path.

The audio path is:

```
HDA Stream → DAC 0x22 → Pin 0x1d → I2S → AW88298 (I2C 0x34) → Left speaker
```

This affects every Chuwi CoreBook X user on Linux. Related upstream issues:

- [thesofproject/linux#5687](https://github.com/thesofproject/linux/issues/5687)
- [thesofproject/sof#10607](https://github.com/thesofproject/sof/issues/10607)
- [bugzilla.kernel.org#221255](https://bugzilla.kernel.org/show_bug.cgi?id=221255)
- [dianjixz/aw882xx#1](https://github.com/dianjixz/aw882xx/issues/1)

## Status

- **Userspace daemon**: working, stable, validated under real usage including
  suspend/resume and headphone plug/unplug. This is what this repo currently
  ships.
- **Kernel patch**: in progress, not published here yet. It will land in this
  repo once it is fully implemented and tested — including the Force Boost
  fix, the volume mirror as a proper ALSA `kcontrol`, and the post-resume
  HDA power cycle. Until then, the daemon is the recommended path.
- **Full story**: [`HISTORY.md`](HISTORY.md) is the project log, from the
  first I2C probe to the Force Boost breakthrough. A narrative version of
  the Force Boost discovery is on the author's blog:
  [pacomont.github.io/chuwi-left-speaker/part-2/](https://pacomont.github.io/chuwi-left-speaker/part-2/).

## Quick start (for other Chuwi CoreBook X owners)

Requirements: Linux kernel with HDA support (any recent mainline),
`alsa-tools` (for `hda-verb`), `i2c-tools`, and `systemd`.

```bash
# 1. Clone this repo
git clone https://github.com/Dmitriy-Romanov/chuwi-corebook-x-left-speaker.git
cd chuwi-corebook-x-left-speaker

# 2. Install the daemon as a systemd service
sudo cp aw88298-daemon.sh /usr/local/bin/aw88298-daemon
sudo chmod +x /usr/local/bin/aw88298-daemon
sudo cp aw88298.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now aw88298
```

Both speakers should now work. The system volume slider moves them together,
and plugging in headphones mutes both correctly.

## What the daemon does

1. **Configures the AW88298** over I2C (`SYSCTRL`, `SYSCTRL2`, `I2SCTRL`,
   `HAGCCFG1/2`, `BSTCTRL2`), including the critical fix of forcing
   `BST_MODE = 001` (Force Boost) to eliminate startup glitches caused by
   the default Smart Boost 2 mode, which idles the boost converter during
   digital silence and takes ~100–200 ms to re-engage when signal returns.
2. **Re-applies the HDA stream mirror** on every poll tick: `DAC 0x11` is
   forced to stream-channel 1 (right only), `DAC 0x22` is given the same
   stream with channel 0 (left only), and its format is copied from
   `DAC 0x11`. This fights the HDA parser, which does not know that
   `DAC 0x22` is part of a playback path and would otherwise reset it.
3. **Mirrors the ALSA "Speaker Playback Volume"** from `DAC 0x11` amp to
   `DAC 0x22` amp with a calibrated −10 offset, preserving the mute bit
   (bit 7), so that plugging headphones silences both speakers.
4. **Recovers after suspend/resume**: when it detects the AW88298 powered
   down, it power-cycles `DAC 0x22` and `pin 0x1d` (`D3 → D0`) to wake up
   the SN6180's internal I2S link, then re-initializes the AW88298.

## Diagnostic tools

Two small scripts for when something looks wrong and you want to see what
the AW88298 is actually doing:

- [`sample-sysst.sh`](sample-sysst.sh): a passive, high-frequency sampler
  that reads `SYSST`, `PVDD`, `VBAT`, `TEMP`, `ISNDAT`, and `VSNDAT`, and
  prints only when a value changes. Useful for catching transient boost
  converter or switching-stage events during playback. Never reads
  `SYSINT` — that register is read-clear, so polling it destroys the
  very evidence you want to look at.
- [`oneshot-sysint.sh`](oneshot-sysint.sh): a single-shot read of `SYSINT`,
  for capturing interrupt flags at a specific instant (e.g., right after
  a suspected protection event) without destroying the history by polling.

## The Force Boost finding (short version)

The `AW88298` `BSTCTRL2` register (`0x61`) bits `[14:12]` control the
boost converter mode. The chip defaults to Smart Boost 2, which is designed
to save power by shutting down the boost converter during digital silence
and re-engaging it when a signal returns. On a laptop with bursty audio
(notifications, dialogue, short system sounds), that re-engagement latency
is audible as a glitch at the start of every sound event.

The fix is a single read-modify-write on `BSTCTRL2` that sets
`BST_MODE = 001` (Force Boost) while preserving `BST_TDEG` (bits `[10:8]`)
and `VOUT_VREFSET` (bits `[5:0]`):

```bash
# Current value on reset: 0x6673 BE
# After the fix:           0x1673 BE  (little-endian on the I2C bus: 0x7316)
sudo i2cset -y 0 0x34 0x61 0x7316 w
```

Full derivation, including the `SYSST` sampler methodology that surfaced
the root cause, is in [`HISTORY.md`](HISTORY.md) and in the
[blog post](https://pacomont.github.io/chuwi-left-speaker/part-2/).

## Repository layout

```
.
├── README.md             # this file
├── HISTORY.md            # full project narrative
│
├── aw88298-daemon.sh     # userspace workaround
├── aw88298.service       # systemd unit file
│
├── sample-sysst.sh       # passive SYSST sampler (diagnostic)
└── oneshot-sysint.sh     # single-shot SYSINT reader (diagnostic)
```

## License

GPL-2.0-or-later.

## Author

Francisco Montañés García ([@pacomont](https://github.com/pacomont))
