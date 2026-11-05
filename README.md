# raptor-pb4

[Raptor](https://github.com/johnchia/raptor) on the **Vatilon PB4** IP camera
(Fullhan **FH8856V200** + GalaxyCore **GC4653**), built into an
[OpenIPC](https://openipc.org) firmware image.

Raptor had no Fullhan support. This brings it up through a new HAL backend,
`src/fhan_v2`, plus a few Raptor changes, and packages the result so a PB4
boots straight into it.

| | Branch |
|---|---|
| Fullhan HAL backend | [BlackStump/raptor-hal](https://github.com/BlackStump/raptor-hal/tree/fullhan) `fullhan` |
| Raptor (build integration, ric PWM IR, GPIO naming) | [BlackStump/raptor](https://github.com/BlackStump/raptor/tree/fullhan) `fullhan` |
| PB4 packaging (this repo) | `pb4pkg/` |

## What works

- **Video:** GC4653 at its native 2560x1440@25 (sensor mode `0x603`).
- **Two streams over RTSP:** main 2560x1440 H.264 Main at 4 Mbit/s, sub
  640x360 H.264 Baseline at 1 Mbit/s (browser/WebRTC-friendly). H.265 also
  works. CBR and VBR hold their targets.
- **Snapshots and MJPEG** from the main stream (`/snap.jpg`, `/mjpeg`).
- **Day/night:** exposure x gain trigger, the latching IR-cut filter, the IR
  LEDs (driven by ric over PWM), and the vendor day/night ISP tunings with
  auto-exposure kept running under both.
- **Web console** on port 8080 (rhd + rcd).
- **Boots unattended** from the image: modules, pin setup, then Raptor.

Not yet: OSD, anti-flicker, black-and-white at night (night stays in colour,
IR gives it a purple cast), motion-triggered white light.

## Hardware notes (PB4)

| Function | Pin / channel |
|---|---|
| IR-cut filter in (day) | GPIO0, pulse ~150 ms |
| IR-cut filter out (night) | GPIO1, pulse ~150 ms |
| IR-cut rail | GPIO26, held high |
| IR LEDs | PWM 3 (this housing) |
| White LEDs | PWM 2 (this housing) |
| Sensor reset | GPIO13 |

GPIO0/1 default to PWM6/7 and GPIO26 to SADC; `S95pb4` muxes them with
`devmem`. The kernel names exported pins `GPIO<N>`. The PWM channel order of
the lamps depends on the housing's LED board: verify it in a new housing.
PWM writes go to `/proc/driver/pwm` as `<chn>,12,<duty_ns>,<period_ns>,0,0,0,0`
(12 = the enable mask for channels 2 and 3).

Memory: `mem=32M`, VMM pool `0xA2000000`, **64M** (set in `load_fullhan`);
32M is not enough for two streams.

## Findings worth knowing

These came out of the port and apply to any FH885xV200 software:

- **Rate control.** `FH_VENC_SetRCAttr` is a switch on the mode word that
  copies selected input words into a 26-word kernel block. In CBR mode the
  inputs are: initial QP, bitrate (bit/s), frame rate (`fps | 1<<16`), then
  words that land in the statistics window (vendor default 5) and its flag
  (1). The layout used by divinus put the frame rate in the window slot, so
  the loop never converged ("CBR ignores its target"). With the right layout,
  CBR and VBR hold their targets. Details in `raptor-hal/src/fhan_v2/fh_encoder.c`.
- **The night tuning stops auto-exposure.** Loading `*_night_attr.hex`
  freezes exposure and gain. Writing back the AE default configuration the
  day tuning set (`API_ISP_SetAeDefaultCfg`) right after the night load keeps
  AE running with the night file's other settings.
- **ISP queries are not thread-safe** against `API_ISP_Run`: read AE status
  from the 3A thread only.
- **`FH_VENC_GetStream` is not per channel**; one collector thread drains it
  and dispatches frames.
- **One MJPEG encoder** on this SoC.
- **The vendor libraries are uClibc builds** on a musl userland: `mmap`
  needs a caller-dispatched shim (32-bit `off_t` at `sp+4`), and the
  backend's own symbols must be hidden or libdsp binds to them.

## Building

Needs an OpenIPC Fullhan build tree (Buildroot output for `fh8856v200`), the
Raptor repos side by side, and [compy](https://github.com/gtxaspec/compy)
built with mbedTLS:

```
PB4/
  openipc-fh/output/          OpenIPC Buildroot output
  raptor/raptor               BlackStump/raptor,     branch fullhan
  raptor/raptor-hal           BlackStump/raptor-hal, branch fullhan
  raptor/raptor-common        johnchia/raptor-common @ 2a2fc69
  raptor/raptor-ipc           johnchia/raptor-ipc    @ a8cd4ca
  raptor/compy/build-arm      compy, CMake, -DCOMPY_TLS_MBEDTLS=ON
  pb4pkg/                     this repo
```

compy:

```
cd raptor/compy
PKG_CONFIG=$OUT/host/bin/pkg-config cmake -B build-arm \
  -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm \
  -DCMAKE_C_COMPILER=$OUT/host/bin/arm-openipc-linux-musleabi-gcc \
  -DCMAKE_SYSROOT=$OUT/host/arm-openipc-linux-musleabi/sysroot \
  -DCOMPY_TLS_MBEDTLS=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build-arm -j4
```

Then:

```
sh pb4pkg/mkpb4.sh overlay   # build the daemons, assemble the overlay tree
sh pb4pkg/mkpb4.sh image     # ...and put it into the image: Majestic, Divinus
                             # and wlight removed, 64M pool, images rebuilt
```

Edit the paths at the top of `mkpb4.sh` to match your tree.

## Flashing

From the camera, with the two images copied to `/tmp`:

```
sysupgrade -f --kernel=/tmp/uImage.fh8856v200 --rootfs=/tmp/rootfs.squashfs.fh8856v200
```

`-f` is needed: local builds share one version name, and without it the
updater skips the flash as "same version".

To return to the image's `/etc/raptor.conf` after editing it on the camera,
delete the overlay copy (`rm /overlay/root/etc/raptor.conf`), not
`/etc/raptor.conf` itself, which would hide the image's copy too.

## Files

- `pb4pkg/overlay/etc/raptor.conf` - PB4 config: streams, IR-cut, IR PWM,
  gain thresholds.
- `pb4pkg/overlay/etc/init.d/S95pb4` - pin mux, IR-cut rail, lamps off.
- `pb4pkg/mkpb4.sh` - build and package.
- `tools/dntest.sh` - guided day/night test on the camera.
- `tools/codectest.sh` - rate-control check per codec and mode.

## Credits

- **Raptor** and its HAL design: [johnchia](https://github.com/johnchia)'s
  Raptor fork (from [gtxaspec](https://github.com/gtxaspec)'s Raptor).
- **Fullhan reference code:** [OpenIPC divinus](https://github.com/OpenIPC/divinus),
  including Sergey Novak's GC4653 mode selection.
- **FH8852V201 reverse engineering:**
  [pavliha/fh8852v201-dump](https://github.com/pavliha/fh8852v201-dump),
  which pointed the way to the rate-control layout.
- **Bench work, testing and the PB4:** BlackStump.
- Developed with Claude (Anthropic).
