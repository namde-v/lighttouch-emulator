# qemu-ios Linux build log — worker A (Phase 4)

- Repo: https://github.com/samhenrigold/qemu-ios, branch `main`
- Pinned commit: `cb3595e8add3d9a3a55807186c6b8ff0ba338abe` (verified via `git rev-parse HEAD`)
- Machine: Linux x86_64, 2 vCPU, 7.7 GB RAM, no swap; 96 GB free on /home/hatch
- Build dir: `~/workspace/lighttouch-cross/emulator/qemu-ios/build` (NOT `/tmp`: tmpfs is 512 MB)
- `TMPDIR=/home/hatch/.cache/swift-tmp`, `make -j2`

## 1. Clone

```
git clone --depth 1 --branch main https://github.com/samhenrigold/qemu-ios qemu-ios
git fetch --depth 1 origin cb3595e8add3d9a3a55807186c6b8ff0ba338abe
git checkout cb3595e8add3d9a3a55807186c6b8ff0ba338abe   # detached HEAD at cb3595e8
```

## 2. Docs vs reality

- `RUNNING.md` at this commit documents the **macOS** build (`brew install …`,
  `--extra-cflags=-I/opt/homebrew/opt/openssl@3/include …`). It has **no Linux
  section**; the only Linux-ish line is the ancient Ubuntu dep list the task
  quoted.
- `README.md` "Build" documents a *different*, newer flow:
  `../scripts/configure-patched-ffmpeg && ../scripts/ccninja qemu-system-arm`
  — meson configure, `--target-list=arm-softmmu`, `--disable-sdl` (headless),
  `--disable-pie`, linking against a **patched FFmpeg**
  (`contrib/ffmpeg/h264-chunk-er.patch`). That script is macOS-only
  (`/opt/homebrew` paths, `-mmacosx-version-min=12.0`) and expects
  `FFMPEG_PREFIX`. The RUNNING.md `--enable-sdl` configure line the task gave
  is the older standalone-emulator flow; it still configures and builds.
- Also of note: the build gates are `tests/gate.sh --quick|--models|--all`
  (host-only slice tests + device qtests), not `make check`.

## 3. Dependencies installed (Ubuntu 24.04, `apt`)

Task-listed (all present in archive, installed cleanly):

| package | version |
|---|---|
| make | 4.3-4.1build2 |
| ninja-build | 1.11.1-2 |
| pkg-config | 1.8.1-2build1 |
| libssl-dev | 3.0.13-0ubuntu3.16 |
| libsdl2-dev | 2.30.0+dfsg-1ubuntu3.1 |
| libpixman-1-dev / libpixman-1-0 | 0.42.2-1build1 |
| libglib2.0-dev | 2.80.0-6ubuntu3.9 |
| gcc (cc) | 13.3.0 (Ubuntu 13.3.0-6ubuntu2~24.04.1) |

Missing but required by configure — installed additionally (docs don't mention them):

| package | version | why |
|---|---|---|
| meson | 1.3.2-1ubuntu1 | QEMU's build system |
| bison | 2:3.8.2+dfsg-1ubuntu0.24.04.1 | QEMU configure requirement |
| flex | 2.6.4-8.2build1 | QEMU configure requirement |
| libfdt-dev | 1.7.0-2build1 | device tree for arm-softmmu |
| device-tree-compiler | 1.7.0-2build1 | `dtc` program check |
| time | 1.9-0.2build1 | for `/usr/bin/time -v` build stats |
| zlib1g-dev | 1:1.3.dfsg-3.1ubuntu2.2 | already present on the image |

Python 3.12.3 (system) was accepted by configure's venv step without the
`distlib` problem RUNNING.md documents for Homebrew Python.

## 4. Configure

Command (exactly the documented one):

```
../configure --enable-sdl --disable-cocoa --target-list=arm-softmmu \
  --disable-capstone --disable-slirp \
  --extra-cflags=-I/usr/include/openssl --extra-ldflags='-lcrypto' \
  --disable-werror --enable-pie
```

Result: **success** — with one environment-specific fix:

- **Meson subproject fetches from `gitlab.com` fail** on this machine:
  `git fetch` to `gitlab.com/qemu-project/*.git` dies with
  `curl 56 GnuTLS recv error (-110): The TLS connection was non-properly
  terminated` (persistent, retried many times; GitHub works fine). Affected
  wraps: `keycodemapdb`, `berkeley-softfloat-3`, `berkeley-testfloat-3`
  (the other gitlab wraps — `dtc`, `libblkio`, `libvfio-user` — are not needed
  for this target set and were never requested by meson).
- Fix: fetched the exact pinned revisions from the official GitHub mirrors
  into the subproject dirs manually:
  - `github.com/qemu/keycodemapdb` @ `f5772a62ec52591ff6870b7e8ef32482371f22c6`
  - `github.com/qemu/berkeley-softfloat-3` @ `b64af41c3276f97f0e181920400ee056b9c88037`
  - `github.com/qemu/berkeley-testfloat-3` @ `e7af9751d9f9fd3b47911f51a5cfd08af256a9ab`
  and replicated meson's `patch_directory` overlay by copying
  `subprojects/packagefiles/berkeley-{softfloat,testfloat}-3/{meson.build,meson_options.txt}`
  into the corresponding subproject dir. Revisions match the `.wrap` files
  byte-for-byte; sources are the same upstream mirrors.
- No changes to configure flags were needed. `--disable-cocoa` is accepted
  (no-op on Linux).

Configure summary: `sdl: enabled, slirp: disabled, capstone: disabled,
cocoa: disabled, docs: disabled, plugins: true, werror: false`.

## 5. Build

```
make -j2
```

**Result: SUCCESS.** `build/qemu-system-arm` (101 MB) links and runs.

- First full build: **10 min 20 s wall** (2 vCPU, `make -j2`; 691 s user CPU,
  130% CPU). Peak system memory pressure was fine — no OOM, no swap (none
  configured); lowest observed available RAM during compile was ~660 MB.
  (`/usr/bin/time -v` max RSS of the make driver itself: 329 MB.)
- One genuine source bug hit at link time (details below); after the fix,
  incremental rebuild + relink took ~2 min.
- Only 10 benign compiler warnings with `--disable-werror` (unused variables,
  `-Wshadow=local`, format-truncation notes) — no errors.

### The one build failure: `undefined reference to 'amc_local'`

Final link of `qemu-system-arm` failed:

```
/usr/bin/ld: libqemu-arm-softmmu.a.p/hw_arm_ipod_touch_amc.c.o: in function `amc_engine0':
../hw/arm/ipod_touch_amc.c:1044: undefined reference to `amc_local'   (x5 refs)
```

Root cause: in `hw/arm/ipod_touch_amc.c`, the helpers `amc_dram()`,
`amc_local()`, `amc_dma_addr()` are defined inside `#ifdef IT_HAVE_AVCODEC`
(which is only set when `libavcodec`+`libavutil` are found by pkg-config),
but `amc_engine0()` — unconditional code — calls `amc_local()`. The `#else`
stub block covers `amc_decoder_close`/`amc_decode_dma`/`amc_decode_publish`/
`amc_decode_drain` but not these three helpers. So any build **without**
FFmpeg dev libraries fails at link. Upstream never sees it because their flow
always configures against (patched) FFmpeg.

Fix (minimal, in `hw/arm/ipod_touch_amc.c`; saved as
`../amc-nonavcodec-fix.patch`): moved the three helpers — pure address-range
checks with no FFmpeg dependency (constants come from unguarded `#define`s in
`include/hw/arm/ipod_touch_amc.h`) — above the `#ifdef IT_HAVE_AVCODEC`.
No behavior change when FFmpeg is present. One false start: the first edit
placed them after the `#ifdef` line (still guarded); corrected and verified
via `nm` that `amc_local` is now defined in the object.

Alternative considered: installing `libavcodec-dev`/`libavutil-dev` to define
`IT_HAVE_AVCODEC`. Rejected: the README explicitly requires the *patched*
FFmpeg (stock FFmpeg fails `tests/slice/ipod-h264-slices.c`), and the
documented Ubuntu flow has no FFmpeg at all. The source fix is correct
regardless of FFmpeg presence.

### Verification

```
$ ./qemu-system-arm --version
QEMU emulator version 11.0.3
$ ./qemu-system-arm -M ? | grep -iE "ipod|iphone|ipad|n18|n88"
iPhone-2G / iPhone-4 / iPod-Touch-1G / iPod-Touch-4G / iPod-Touch /
ipad1 / n18 / n88        # all 8 iOS machines registered
$ ./qemu-system-arm -M iPod-Touch,bootrom=/nonexistent -display none
qemu-system-arm: bootrom at path "/nonexistent" must exist   # clean error, no crash
```

`ldd` shows 64 shared deps incl. libSDL2, libcrypto.so.3, libpixman-1,
libglib-2.0. Note: no guest firmware images are available here, so no actual
guest boot was attempted — the binary is verified to start, enumerate
machines, and validate arguments.

Artifacts: `build/qemu-system-arm` (the emulator), `build/qemu-img`,
`build/qemu-io`, unit test binaries under `build/tests/`. Build tree is
1.5 GB.

## 6. `make-dylib-macos.sh` → Linux notes

See `DYLIB_RELINK_NOTES.md` in this directory (mechanics only; the ABI symbol
list is another worker's).

## 7. `contrib/ffmpeg/h264-chunk-er.patch`

- Exists at the pinned commit (541 bytes).
- Targets `libavcodec/h264dec.c` — the **classic (pre-refactor) H.264 decoder**.
- Verified by dry-run `patch -p1`:
  - **FFmpeg 6.1.2: applies cleanly** (hunk offset -4 lines; target line 778).
    This is Ubuntu 24.04's FFmpeg generation (archive has 6.1.1).
  - FFmpeg 7.1.1: applies cleanly (offset +2).
- Conclusion: the patch is version-agnostic across the FFmpeg 6.x/7.x
  `h264dec.c` layout — any 6.x/7.x tree is a plausible build target. (FFmpeg
  8.x not checked; no full FFmpeg build was done per task scope.)

## 8. Test gates on Linux (extra validation, beyond the build)

`tests/gate.sh --quick` as written **cannot run on Linux**: `tests/slice/run.sh`
hardcodes `xcrun clang`, and the guest-package/toolchain tests shell out to
`contrib/armv6-toolchain/armv6.sh` (also `xcrun`-based). Result: 0/135 pass,
all in ~0 s, every log ending in `xcrun: command not found`.

Porting note: substituting `cc` for `xcrun clang` in `run.sh` is sufficient to
run the slice tests on Linux. Did that (throwaway copy, not committed) and ran
all slice tests: **91 PASS / 35 FAIL** (full per-test list in
`slice-linux-results.txt`; raw logs in `gate-out/`).

Failure categories (all expected porting work, none caused by this build):

| Category | Tests | Notes |
|---|---|---|
| macOS system headers | `ipod-darwin-poll` (`sys/event.h`), `ipod-agent-ops`, `ipod-agent-orientation` (`mach/mach.h`) | need Linux equivalents |
| Apple crypto headers | `ipod-sha1-dma`, `ipod-sha1-irq`, `ipod-pvrtc`, `ipod-pvrtc-upload`, `ipod-iboot-literals` (`CommonCrypto/*`) | Linux port uses OpenSSL instead |
| Apple frameworks / ObjC | all 15 `ipod-gles-*`, `ipod-mpvd-replay` (`-framework`, `-fobjc-arc`) | need Linux GL/ObjC story |
| Missing FFmpeg dev libs | `ipod-h264-slices`, `s5l8920-vxd-h264` (test body compiled out → no `main`), `ipod-amc-aac`, `ipad1-jpeg-encode`, `ipod-media-helpers`, `ipod-harness-pcm`? | need the patched-FFmpeg build; `h264-slices` is the test the README says catches stock FFmpeg |
| Missing `-lm` in link | `ipad1-clcd-gamma`, `ipad1-compass`, `ipod-accel-sampling`, `ipod-lcd-gamma` (`lround`) | one-word harness fix on Linux |
| Missing `#include <stdbool.h>` | `ipod-media-helpers` | macOS headers transitively provide it |
| Test-harness/env | `ipod-harness-pcm` (`mkdtemp` assertion in this environment) | env-specific, investigate |
| **Possible real bug** | `ipod-mrvl8686`: UBSan `null pointer passed as argument 2` at `ipod-mrvl8686.c:48` | may be glibc-vs-macOS-libc annotation difference, or a genuine bug — flagged for follow-up |

Not run: `tests/gate.sh --models` (device qtests — need firmware images, not
available here) and the `tests/sessions` Swift boots (LightTouchMac side).

## 9. Files in this directory

- `qemu-ios/` — the clone at `cb3595e8add3d9a3a55807186c6b8ff0ba338abe`
  (+1 minimal source fix, see §5; +meson subproject checkouts, see §4).
  `build/qemu-system-arm` is the built emulator.
- `qemu-ios-abi/` — another worker's clone; untouched.
- `BUILD_LOG.md` — this file.
- `DYLIB_RELINK_NOTES.md` — mechanics for a Linux `make-so-linux.sh`.
- `amc-nonavcodec-fix.patch` — the `ipod_touch_amc.c` fix as a patch file.
- `slice-linux-results.txt`, `gate-out/` — slice-test evidence (§8).
- `ABI_CONTRACT.md` — another worker's file; untouched.
