# How we fixed the left speaker on the Chuwi CoreBook X in Linux

**A 5-week journey through the guts of Linux audio: ACPI, HDA, I2C, I2S, and an undocumented chip.**

---

## The problem

The Chuwi CoreBook X is an AMD Ryzen 5 7430U laptop with a Linux defect: only the right speaker works. The left one is completely silent. Windows works — but only with Chuwi's OEM driver. A clean Windows install fails too.

This affects every user of this laptop on Linux. There are reports in Chuwi forums, in the kernel bugzilla, and in the SOF (Sound Open Firmware) tracker.

## Initial investigation (March 2026)

### Two speakers, two worlds

The first step was understanding the laptop's audio architecture. Dumping the HDA codec info:

```
$ cat /proc/asound/card1/codec#0
Codec: Conexant SN6180
Vendor Id: 0x14f120d1
Subsystem Id: 0x27821221
```

The **Conexant SN6180** is the main HDA codec. It has an integrated Class-D amplifier that drives the right speaker through pin 0x17. This works perfectly in Linux.

But the left speaker is not connected to the SN6180. So what is it connected to?

### The ghost chip

Digging into the ACPI table (which describes the hardware to the OS), we found a mysterious device:

```
Scope (_SB.I2CB)
{
    Device (CHIP)
    {
        Name (_HID, "AWDZ8298")
        // I2C addresses: 0x34 and 0x35 at 400kHz
        // GPIO: pin 121 (reset)
    }
}
```

**AWDZ8298** — an AWINIC device on the AMD I2C bus. After investigating, we identified the chip: an **AWINIC AW88298**, a Smart PA Class-D amplifier. It is a chip specialised in amplifying audio for small speakers, with integrated thermal protection, gain control, and a boost converter.

### First contact over I2C

The chip is alive and responding:

```bash
$ sudo i2cget -y 0 0x34 0x00 w
0x5218    # Byte-swap → 0x1852 = PID of the AW88298 ✓
```

The AW88298 uses 16-bit big-endian registers, but `i2cget` returns bytes in little-endian order (SMBus protocol). This means every read needs a mental byte-swap: `0x5218` is actually `0x1852`.

Reading the status register:

```bash
$ sudo i2cget -y 0 0x34 0x01 w
0x2000    # → BE 0x0020 → bit5 NOCLKS = 1
```

**NOCLKS** — "No clock." The chip is powered on but receiving no audio signal. It needs an I2S (Inter-IC Sound) clock from somewhere, and nobody is providing one.

## False leads

### "It's the AMD ACP" (spoiler: it's not)

Our first hypothesis was that the **AMD Audio Co-Processor (ACP)** should be providing the I2S signal to the AW88298. The ACP is a dedicated audio processor inside the AMD SoC that can handle I2S and PDM interfaces.

We opened issues on the SOF and Linux kernel trackers. The response from AMD (Vijendar Mukunda, audio team engineer) was clear:

> *"There is no role of ACP IP here. It's purely HDA stack use case where I2S based amplifiers are connected to HDA codec."*

AMD was saying the ACP was not involved and that this was a "pure HDA stack" case, similar to how Cirrus Logic connects its CS35L41 amplifiers to Realtek codecs.

### "It's like the CS35L41 with Realtek" (spoiler: almost, but not exactly)

The second lead was the `snd-hda-scodec-cs35l41` driver, which solves an analogous problem: external amplifiers connected to Realtek HDA codecs. The kernel architecture for this is elegant:

1. The HDA codec (Realtek) registers as the **component master**
2. The external amplifier (CS35L41) registers as a **component**
3. When both are present, the **component binding** framework links them
4. The codec calls the amplifier's **playback hooks** to coordinate power on/off

But there is a fundamental difference: Realtek codecs have **documented, dedicated I2S output pins**. The Conexant SN6180 has nothing of the sort in its public documentation. That made us doubt AMD's answer.

### "So it is the ACP after all" (spoiler: still no)

We read the `ACP_I2S_PIN_CONFIG` register directly from the ACP's memory-mapped registers:

```python
# BAR0 = 0xFCD80000, PIN_CONFIG offset = 0x1400
pin_config = read_mmio(0xFCD81400)
# Result: 0
```

**PIN_CONFIG = 0** → I2S disabled on the ACP. The ACP was completely off. AMD was right: the ACP plays no part.

But then... where is the I2S coming from?

## The breakthrough (April 10, 2026)

### The test module

We wrote a kernel module (`aw88298_test.ko`) that does exactly three things:

1. Read the chip ID over I2C (verify communication)
2. Power on the amplifier (clear PWDN, clear AMPPD)
3. Check whether there is an I2S clock (read SYSST)

We loaded it while playing audio through the right speaker:

```bash
$ speaker-test -D hw:1,0 -c 2 -l 0 &
$ sudo insmod aw88298_test.ko
```

And in `dmesg`:

```
aw88298-test: Chip ID verified: 0x1852 (AW88298)
aw88298-test: [INITIAL] PLL=unlocked CLKS=no NOCLKS=no
aw88298-test: PLL locked and I2S clock present!
aw88298-test: [POWER_ON] PLL=locked CLKS=yes NOCLKS=no
aw88298-test: *** TEST RESULT: I2S clock PRESENT ***
```

**The PLL locked.** There is an I2S clock. It comes from somewhere — and it is not the ACP.

### The format test

To confirm this was a real clock and not electrical noise, we changed the I2S configuration of the AW88298 (frame format, BCLK frequency):

```bash
# Switch from 32-bit/64fs to 16-bit/32fs
$ sudo i2cset -y 0 0x34 0x06 0x0814 w
# Result: PLL loses lock → SYSST = 0x0000
```

Changing the format causes the PLL to lose lock. Restoring the original format (32-bit, 64fs, 48kHz) makes it lock again. **The clock is real and has specific parameters.**

### But no audio

Despite the PLL being locked, the amplifier current registers read zero:

```bash
$ sudo i2cget -y 0 0x34 0x15 w  # ISNDAT (current)
0x0000
$ sudo i2cget -y 0 0x34 0x16 w  # VSNDAT (voltage)
0x0000
```

There is a clock but no data. The I2S bus has BCLK and WS (Word Select), but the SDATA line is silent.

### The codec dump that changed everything

We went back to the HDA codec dump and looked at it with fresh eyes:

```
Node 0x10 [Audio Output] — DAC for headphones
Node 0x11 [Audio Output] — DAC for right speaker
Node 0x22 [Audio Output] — extra DAC, stream=0, UNASSIGNED
Node 0x23 [Audio Output] — extra DAC, pin 0x26

Node 0x1d [Pin Complex] — Configured as [N/A], DISABLED
  Connection: 1
     0x22    ← Connected to DAC 0x22!
```

**Four DACs.** The SN6180 has four digital-to-analogue converters, not two. And pin 0x1d — which was disabled with an `[N/A]` configuration — is connected to DAC 0x22.

This is not normal for a plain HDA codec. Two extra DACs and two extra pins strongly suggest the chip was designed for exactly this scenario: an I2S output to an external amplifier.

### The moment of truth

```bash
# 1. Assign the active audio stream to DAC 0x22
$ sudo hda-verb /dev/snd/hwC1D0 0x22 0x706 0x50

# 2. Set the stream format
$ sudo hda-verb /dev/snd/hwC1D0 0x22 0x200 0x11

# 3. Enable pin 0x1d as output
$ sudo hda-verb /dev/snd/hwC1D0 0x1d 0x707 0x40

# 4. Enable EAPD on pin 0x1d
$ sudo hda-verb /dev/snd/hwC1D0 0x1d 0x70c 0x02
```

**"It's playing — loud!"**

The left speaker came to life. After 5 weeks of investigation, 4 open issues, communication with AMD engineers, ACPI register analysis, HDA codec dumps, kernel driver reading, and hundreds of I2C commands... the left speaker was making sound.

## Tuning the stereo

### Channel separation

The first sound was mono — both speakers were reproducing both channels. The trick to achieving true stereo was elegant:

In HDA, each DAC has a **channel** parameter within the stream. If a stereo stream has channel 0 (left) and channel 1 (right), we can tell each DAC to take only one:

```bash
# DAC 0x11 (right): take channel 1 only
$ sudo hda-verb /dev/snd/hwC1D0 0x11 0x706 0x51  # stream 5, channel 1

# DAC 0x22 (left): take channel 0 only
$ sudo hda-verb /dev/snd/hwC1D0 0x22 0x706 0x50  # stream 5, channel 0
```

The AW88298 also has its own channel selector (register I2SCTRL, CHSEL=01 = Left), so it only plays the left channel from the I2S stream. Perfect stereo.

### The clipping problem

With YouTube music, the left speaker was cutting out on peaks. The dropouts were synchronised with the music — every drum hit or loud bass note would cause a brief cut.

Reading the AW88298 interrupt register:

```bash
$ sudo i2cget -y 0 0x34 0x02 w
0x9543  # → BE 0x4395
# CLIPIS = 1  — Clipping detected!
# UVLIS = 1   — Undervoltage!
```

The amplifier was **clipping** on signal peaks and the boost converter could not maintain the voltage. Root cause: **HAGCE = 0** — the Hardware Automatic Gain Control was disabled.

HAGC is an automatic gain control system that dynamically reduces the volume when the signal approaches the amplifier's limit. Without it, peaks are simply hard-clipped.

```bash
# Enable HAGC and raise the boost current limit
$ sudo i2cset -y 0 0x34 0x05 0x6B00 w
# HAGCE=1, BST_IPEAK=11 (4.25A), HMUTE=0
```

The dropouts disappeared completely.

## The full architecture

```
┌─────────────────────────────────────────────┐
│             AMD Ryzen 5 7430U               │
│                                             │
│  ┌──────────┐    HDA Bus    ┌───────────┐   │
│  │ HD Audio │◄────────────►│  Conexant  │   │
│  │Controller│              │  SN6180    │   │
│  └──────────┘              │            │   │
│                            │ DAC 0x11 ──┼──►Pin 0x17──►Class-D──►SPK RIGHT ✓
│                            │            │   │
│                            │ DAC 0x22 ──┼──►Pin 0x1d──►I2S──┐
│                            │            │   │                │
│  ┌──────────┐              └───────────┘   │                │
│  │ I2C Bus  │◄─────────────────────────────┼────┐           │
│  │Controller│    Control (registers)       │    │           │
│  └──────────┘                              │    ▼           ▼
│                                            │ ┌───────────────┐
│                                            │ │  AWINIC       │
│                                            │ │  AW88298      │
│                                            │ │  Smart PA     │
│                                            │ │               │
│                                            │ │  I2C: 0x34    │
│                                            │ │  ACPI: AWDZ8298│
│                                            │ └───────┬───────┘
│                                            │         │
└────────────────────────────────────────────┘         ▼
                                                  SPK LEFT ✓
```

Two completely separate audio paths:
- **Right**: HDA → DAC 0x11 → SN6180 internal Class-D amplifier → speaker
- **Left**: HDA → DAC 0x22 → pin 0x1d → digital I2S → external AW88298 → speaker

The AW88298 is controlled over I2C (a bus separate from the audio path). The audio itself travels over I2S from the HDA codec.

## The registers that matter

### Conexant SN6180 (HDA verbs)

| Action | Verb | Parameter | Description |
|--------|------|-----------|-------------|
| Stream → DAC 0x22 | 0x706 | `<stream_id>0` | Assign stream, channel 0 (left) |
| Stream → DAC 0x11 | 0x706 | `<stream_id>1` | Assign stream, channel 1 (right) |
| DAC 0x22 format | 0x200 | `<format>` | Copy format from active stream |
| Pin 0x1d output | 0x707 | 0x40 | Enable pin as output |
| Pin 0x1d EAPD | 0x70c | 0x02 | Enable pin output amplifier |
| DAC 0x22 volume | 0x300 | 0xb030/0x9030 | L/R at calibrated level |

### AWINIC AW88298 (I2C registers)

| Register | Address | Value | Description |
|----------|---------|-------|-------------|
| SYSCTRL | 0x04 | 0x3040 | SPK_GAIN=AV14, I2SEN=1, PWDN=0, AMPPD=0 |
| SYSCTRL2 | 0x05 | 0x006B | **HAGCE=1**, BST_IPEAK=11(4.25A), HMUTE=0 |
| I2SCTRL | 0x06 | 0x14E8 | Philips I2S, 32-bit, 64fs, 48kHz, channel L |

A note on endianness: the AW88298 is big-endian. With `i2cset`/`i2cget` (SMBus, little-endian), bytes are swapped. The value 0x3040 is written as `i2cset -y 0 0x34 0x04 0x4030 w`.

## The kernel patch

The definitive fix is ~460 lines of new kernel code:

### 1. `conexant.c` — Component binding + fixup

**Component binding** support is added to the Conexant driver (which never had it — we are the first). The fixup for the Chuwi CoreBook X (subsystem ID `0x2782:0x1221`):

- Enables DAC 0x22 and pin 0x1d
- Configures channel separation (DAC 0x11 = R, DAC 0x22 = L)
- Registers a playback hook that coordinates with the AW88298
- Binds to the side-codec by ACPI HID `AWDZ8298`

### 2. `aw88298_hda.c` — Side-codec driver

An I2C driver that:

- Detects the AW88298 by ACPI HID `AWDZ8298`
- Verifies the chip ID (PID 0x1852)
- Registers itself as an HDA component (`component_add`)
- In the **playback hook**:
  - `OPEN`: wake the chip (pm_runtime)
  - `PREPARE`: power on → PLL check → HAGC on → unmute
  - `CLEANUP`: mute → power off
  - `CLOSE`: suspend the chip

### 3. `aw88298_hda_i2c.c` — I2C transport

60 trivial lines of code: matches the ACPI HID, creates the I2C regmap, and calls the main probe.

## Lessons learned

1. **AMD was right** — but their answer was so terse we almost dismissed it. "Pure HDA stack case" is technically correct, but it explains nothing. It took us weeks to prove it.

2. **Public documentation lies by omission** — the SN6180 does not publicly document its I2S capability. But the hardware is there: 4 DACs, I2S pins, all wired on the PCB.

3. **The first test module was the key** — without it, we would still be arguing about whether the I2S comes from the ACP or the codec. 30 lines of C code settled the question in 3 seconds.

4. **HAGC is mandatory** — without automatic gain control, the amplifier clips on signal peaks. This is not obvious until you play real music (test tones have no peaks).

5. **The kernel's component binding framework is elegant** — it already existed for exactly this use case. We just needed to adapt it to Conexant (which had never needed it before).

## Epilogue (April 12, 2026): the Force Boost discovery

The daemon was running, the left speaker was sounding. But there was a persistent problem we had been wrestling with for days: **dropouts at the start of every sound**. With continuous music, flawless. With a dialogue video, short notifications, or L/R channel-switching in a test, the first half-second of each burst came out garbled or was lost entirely.

We tried everything: adjusting SPK_GAIN, raising and lowering BST_IPEAK, toggling HAGC, re-applying the stream mirror every 100 ms, moving the DAC amp from 0x30 to 0x4a... Nothing fixed the initial delay. I even added `SYSINT` to the polling loop thinking that "clearing transient flags" would help — a rookie mistake: `SYSINT` is read-clear, so polling it was destroying the interrupt history before it could be inspected. Removing it brought things back to where they were.

### The experiment that changed everything

I stepped back, took a breath, and reframed the situation: **measure before acting**. I had spent days reading the datasheet looking for what to *write*, and I had never stopped to think about what I could *read*. A high-frequency sampler on `SYSST` (the read-only status register, not the self-clearing `SYSINT`) was obvious in hindsight, and it would capture exactly which bits were changing at the precise moment of the dropout.

I put the script together in 5 minutes: a bash loop reading `SYSST`, `PVDD`, `VBAT`, `TEMP`, `ISNDAT`, `VSNDAT` in a tight loop, printing only when a value changed. Millisecond-precision timestamps. Zero intrusion: reads only.

I ran it for 30 seconds with the L/R test video in the background, and the pattern showed up on the first pass:

```
T+00:00.700  SYSST=0x2811 [PLLS CLKS]             ← during silence on L
T+00:00.737  SYSST=0x0311 [PLLS CLKS WDS BSTS]    ← just as signal arrives
T+00:00.842  SYSST=0x2811 [PLLS CLKS]             ← back to silence
```

The `WDS` (Amplifier Switching Status) and `BSTS` (Boost Start-up Finished) bits were going from **1 to 0 during digital silences** and back to 1 when signal was detected. The chip was **shutting down its switching stage and boost converter every time the audio dropped to zero**, even though PLL and clock remained active. When signal returned, the chip took those ~100–200 ms to re-engage both → the audible dropout.

### `BSTCTRL2` and Smart Boost 2

The culprit lived in a register I had never touched: `BSTCTRL2 (0x61)`, bits [14:12] → `BST_MODE`. Initial hardware read:

```
BSTCTRL2 = 0x6673 BE
           bits[14:12] = 110 = Smart Boost 2  ← default mode!
           bits[10:8]  = 110 = BST_TDEG
           bits[5:0]   = 0x33 = VOUT_VREFSET
```

The aw882xx documentation (PID 1852) is explicit:

- **`000` Transparent** — boost in bypass
- **`001` Force Boost** — boost is *always* active
- **`101` Smart Boost 1**
- **Others (incl. `110`) → Smart Boost 2** — *the boost shuts down when the audio level drops below the threshold and restarts when it rises again*

Exactly the behaviour we were measuring. The chip came from the factory configured to save power by shutting down during silence; and on a laptop with constant audio bursts, that power saving came at the cost of a dropout at the start of every sound.

The fix was a single `i2cset` doing a read-modify-write to preserve `BST_TDEG` and `VOUT_VREFSET`:

```bash
# 0x6673 & 0x8FFF | 0x1000 = 0x1673 BE  (Force Boost)
# little-endian on the I2C bus: 0x7316
sudo i2cset -y 0 0x34 0x61 0x7316 w
```

The dropouts **disappeared instantly**. Music, video, dialogue, notifications, L/R test — all clean.

### What changed afterwards

With the boost always active, a new headroom margin opened up. The left speaker's volume ceiling was no longer constrained by the boost collapsing to minimum under load, so we recalibrated:

- **Raise SPK_GAIN** on the AW88298 from `AV14` (a mid-range value) to the maximum (bits `111`, AV21/AV7 max per the nomenclature). The analogue stage no longer needed a protection margin.
- **Remove INPLEV**: without Smart Boost 2 we no longer needed the -6 dB input attenuation we had been using as headroom.
- **Raise DAC 0x22 amp** from `0x39` to `0x40` — it now matched DAC 0x11 on the right in perceived volume, something we had been unable to achieve for a week.
- **Volume mirror in the daemon**: the system slider moves `DAC 0x11`; the daemon reads that value on each iteration and writes `DAC 0x22 = max(0, DAC 0x11 - 10)`. A single slider controls both speakers, for the first time ever on this laptop in Linux.

### Final stable configuration

| Element | Value | Set by |
|---|---|---|
| `BSTCTRL2` | `0x1673` BE (Force Boost) | Daemon, RMW preserving TDEG and VREFSET |
| `I2SCTRL` | `0x14E8` BE (INPLEV=0 dB) | Daemon |
| `SYSCTRL` | `0x7040` BE (SPK_GAIN=7, I2SEN=1) | Daemon |
| `SYSCTRL2` | `0x006B` BE (HAGCE=1, BST_IPEAK=11) | Daemon |
| `HAGCCFG1/2` | `0x4079` / `0x7000` BE | Daemon |
| `DAC 0x22 amp` | max = `0x40` | Daemon (mirror of 0x11) |
| `VOL_OFFSET` | 10 steps | Daemon |

### Extra lessons

6. **Measure > guess.** I had spent days trying register combinations based on hypotheses. The solution was in reading the chip's actual state at the exact moment of failure. A passive 50-line bash sampler revealed the root cause in 30 real-world seconds.

7. **Default configuration registers are not always optimal for a laptop.** The AW88298 ships configured to maximise efficiency, assuming continuous music playback. On a machine where audio starts and stops a hundred times a day, that power saving introduces audible artefacts. The fix was not an exotic patch — it was flipping three bits that the manufacturer would never have touched for their usual target (earphones and small speakers with a continuous signal).

8. **Stopping and changing your approach is worth everything.** I was trapped in my own hypotheses, running variations of the same experiment. The inflection point came when I stopped asking "which register do I write next?" and started asking "what is the chip telling me if I watch it live?" Getting to that reframing literally required getting up from my chair.

## Current status (updated 2026-04-12)

- **Final daemon**: `aw88298-daemon.sh` with Force Boost, INPLEV=0, volume mirror, and polling verification. Active as `systemctl enable aw88298`. The left speaker matches the right at maximum volume, no dropouts, and the system slider controls both speakers in a unified way.
- **Kernel patch**: pending integration of Force Boost and volume mirror as `kcontrol` entries in the side-codec. The init sequence equivalent to `setup_amp()` moves to the driver's probe; the daemon's `mirror_volume` function will become a `snd_ctl_notify` hook in the kernel patch.
- **Issues to update** with the discovery:
  - `thesofproject/linux#5687` — add Part II: Force Boost as the cause of the dropouts
  - `thesofproject/sof#10607` — confirm this remains a pure HDA case, now fully resolved at the user level
  - `dianjixz/aw882xx#1` — confirm that the `aw882xx_pid_1852_reg.h` header was key and that `BSTCTRL2` bits [14:12] deserve an explicit documentation note about Smart Boost 2 behaviour with discontinuous audio
  - `bugzilla.kernel.org/221255` — full workaround available in the daemon script

## Credits

- **ujfalusi** (Peter Ujfalusi, TI/Intel) — for pointing in the right direction: "pure HDA setup"
- **vijendarmukunda** (Vijendar Mukunda, AMD) — for confirming that the ACP is not involved
- **BenoitAmauryHage** — for opening the bugzilla report and validating that the problem is reproducible
- **dianjixz** — for publishing the AW882xx driver with the register headers, without which reaching `BSTCTRL2` would not have been possible
- **nadimkobeissi** — for documenting the Legion fix (AW88399) that served as the reference for the HDA side-codec pattern

---

*Francisco Montañés García (pacomont) — April 2026*
