# qemu-ios Windows (x86-64) build plan

Target: build `qemu-system-arm.exe` from the pinned qemu-ios fork
(`~/workspace/lighttouch-cross/emulator/qemu-ios` @ `cb3595e8`,
QEMU 11.0.3 base) on a GitHub Actions `windows-2025` runner via
MSYS2/MinGW-w64 (UCRT64). **Do not modify the qemu-ios source tree** —
all fixes below are applied as patch files at build time.

## 0. Verdict

**Feasible: YES, high confidence (~85%).**

- QEMU 11.0.3 officially supports Windows hosts via MSYS2
  (`docs/about/build-platforms.rst` in-tree: "either hosted on Linux
  (Debian/Fedora) or via MSYS2 on Windows").
- Every Apple-only code path in the fork degrades gracefully on
  non-Apple hosts by design: VideoToolbox/CoreMedia GLES is behind
  `#ifdef __APPLE__` (software fallback), and the meson's
  `host_opengl`/`host_gles` are `appleframeworks` deps with
  `required: false` → not found on Windows → `gles-host-stub.c`
  ("the guest's GLES HLE probe fails cleanly").
- FFmpeg is optional (`IT_HAVE_AVCODEC` is `required: false` in
  `hw/arm/meson.build`); the no-FFmpeg link failure is already fixed
  by `amc-nonavcodec-fix.patch`.
- Only **2 fork files** need small Windows fixes (exact diffs in §3):
  `hw/arm/ipod_touch_fmss.c` (POSIX `mmap`) and
  `hw/arm/ipod_touch_tcp_usb.c` (POSIX sockets + `fcntl`).
- Every build dependency exists as an MSYS2 UCRT64 package (§2).

## 1. Toolchain: MSYS2 UCRT64 via setup-msys2

QEMU upstream recommends the **UCRT64** environment (not MINGW64) for
Windows builds. Use `msys2/setup-msys2@v2`:

```yaml
- name: Set up MSYS2 (UCRT64)
  uses: msys2/setup-msys2@v2
  with:
    msystem: UCRT64
    update: true
    install: >-
      base-devel
      git
      bison
      flex
      mingw-w64-ucrt-x86_64-toolchain
      mingw-w64-ucrt-x86_64-meson
      mingw-w64-ucrt-x86_64-ninja
      mingw-w64-ucrt-x86_64-pkgconf
      mingw-w64-ucrt-x86_64-python
      mingw-w64-ucrt-x86_64-glib2
      mingw-w64-ucrt-x86_64-pixman
      mingw-w64-ucrt-x86_64-SDL2
      mingw-w64-ucrt-x86_64-openssl
      mingw-w64-ucrt-x86_64-zlib
      mingw-w64-ucrt-x86_64-dtc
```

Run all build steps with `shell: msys2 {0}`.

Dependency mapping (Linux `apt` name from BUILD_LOG.md → MSYS2 package):

| Linux (apt)          | MSYS2 (ucrt64)                        | purpose                    |
|----------------------|---------------------------------------|----------------------------|
| make                 | `base-devel` (msys `make`)            | build driver               |
| ninja-build          | `mingw-w64-ucrt-x86_64-ninja`         | meson backend              |
| pkg-config           | `mingw-w64-ucrt-x86_64-pkgconf`       | dep detection              |
| libssl-dev           | `mingw-w64-ucrt-x86_64-openssl`       | libcrypto for AES/SHA code |
| libsdl2-dev          | `mingw-w64-ucrt-x86_64-SDL2`          | display                    |
| libpixman-1-dev      | `mingw-w64-ucrt-x86_64-pixman`        | software rendering         |
| libglib2.0-dev       | `mingw-w64-ucrt-x86_64-glib2`         | QEMU core                  |
| gcc                  | `mingw-w64-ucrt-x86_64-toolchain`     | compiler                   |
| meson                | `mingw-w64-ucrt-x86_64-meson`         | build system (needs ≥1.5)  |
| bison                | `bison` (msys)                        | QEMU configure requirement |
| flex                 | `flex` (msys)                         | QEMU configure requirement |
| libfdt-dev + dtc     | `mingw-w64-ucrt-x86_64-dtc`           | device tree, arm-softmmu   |
| zlib1g-dev           | `mingw-w64-ucrt-x86_64-zlib`          | compression                |
| python3              | `mingw-w64-ucrt-x86_64-python`        | configure venv step        |
| git                  | `git` (msys)                          | subproject fetches         |

Notes:
- GitHub's Windows runners run as Administrator, which satisfies QEMU's
  documented symlink requirement ("Python scripts that call
  `os.symlink()` … the process must be run as an administrator" when
  Developer Mode is off).
- Check out to the default workspace (`D:\a\…`); avoid paths with
  spaces. Do not build under a tmpfs-like location.

## 2. Patches (apply after checkout, before configure)

All applied from the `qemu-ios/` source dir with `patch -p1 < <file>`.

### 2a. `amc-nonavcodec-fix.patch` (already exists)

`../amc-nonavcodec-fix.patch` — required on **all** platforms.
Fixes the no-FFmpeg link failure (`undefined reference to 'amc_local'`
in `hw/arm/ipod_touch_amc.c`). See BUILD_LOG.md §5.

### 2b. NEW: `fmss-win32-mmap.patch`

`hw/arm/ipod_touch_fmss.c` uses POSIX `mmap()` for the packed-NAND
fast path (`fmss_try_map_packed()`). MinGW has no `mmap`. The function
already documents a silent fallback ("a directory still works, just
slower"), so on Windows we skip the fast path entirely:

```diff
--- a/hw/arm/ipod_touch_fmss.c
+++ b/hw/arm/ipod_touch_fmss.c
@@ -6,7 +6,9 @@
 #include "system/runstate.h"
 #include "system/address-spaces.h"
+#ifndef _WIN32
 #include <sys/mman.h>
+#endif
 #include <sys/stat.h>
 #include "trace.h"
 #include "hw/trace-printf.h"
@@ -686,6 +688,9 @@
  */
 static void fmss_try_map_packed(IPodTouchFMSSState *s)
 {
+#ifdef _WIN32
+    return; /* no mmap on Windows; the directory fallback is used instead */
+#endif
     static const char magic[8] = "ITNAND01";
     struct stat st;
     const uint8_t *p;
```

(Later optimization, not for CI: use `CreateFileMapping`/`MapViewOfFile`
to restore the fast path on Windows.)

### 2c. NEW: `tcp-usb-win32-sockets.patch`

`hw/arm/ipod_touch_tcp_usb.c` ("USB over TCP transport") has three
Windows problems:

1. It includes raw POSIX headers `<sys/socket.h>`, `<netinet/in.h>`,
   `<netinet/tcp.h>`, `<sys/un.h>`, `<netdb.h>` — none exist in
   MinGW-w64. (`qemu/osdep.h` is already pulled in transitively via
   `include/hw/arm/ipod_touch_tcp_usb.h`, which brings winsock2.h.)
2. It has an `AF_UNIX` branch for "the bridge's Unix socket" —
   unsupported on Windows.
3. It calls `close()` on socket fds (must be `closesocket()` on
   Windows) and uses `fcntl(F_SETFL, O_NONBLOCK)` (no `fcntl` on
   Windows; QEMU's portable spelling is `qemu_set_nonblock()`).

```diff
--- a/hw/arm/ipod_touch_tcp_usb.c
+++ b/hw/arm/ipod_touch_tcp_usb.c
@@ -34,14 +34,25 @@
  */
 #include "hw/arm/ipod_touch_tcp_usb.h"
 
+#ifndef _WIN32
 #include <sys/types.h>
 #include <sys/socket.h>
 #include <netinet/in.h>
 #include <netinet/tcp.h>
 #include <sys/un.h>
 #include <netdb.h>
+#endif
+/* On Windows, qemu/osdep.h (via the header above) already provides
+ * winsock2.h; MinGW-w64 has no POSIX socket headers. */
+#include "qemu/sockets.h"
 #include "trace.h"
 #include "hw/trace-printf.h"
+
+#ifdef _WIN32
+#define TCP_USB_CLOSE(fd) closesocket(fd)
+#else
+#define TCP_USB_CLOSE(fd) close(fd)
+#endif
@@ -467,6 +478,7 @@
 		char port[16];
 		int fd;
 
+#ifndef _WIN32
 	if (_host[0] == '/') {   /* the bridge's Unix socket */
 		struct sockaddr_un su = { .sun_family = AF_UNIX };
 		if (strlen(_host) >= sizeof(su.sun_path)) {
@@ -478,10 +490,13 @@
 			return -EIO;
 		}
 		if (connect(fd, (struct sockaddr *)&su, sizeof(su)) < 0) {
-			close(fd);
+			TCP_USB_CLOSE(fd);
 			return -EIO;
 		}
 		goto connected;
 	}
+#else
+	(void)_host; (void)_port;
+	return -EINVAL; /* no AF_UNIX bridge on Windows; use TCP host:port */
+#endif
 
 	snprintf(port, sizeof(port), "%u", _port);
@@ -496,7 +511,7 @@
 	}
 
 	if (connect(fd, res->ai_addr, res->ai_addrlen) < 0) {
-		close(fd);
+		TCP_USB_CLOSE(fd);
 		freeaddrinfo(res);
 		return -EIO;
 	}
@@ -513,8 +528,7 @@
 	_state->amount_done = 0;
 
-	int flags = fcntl(fd, F_GETFL, 0);
-	fcntl(fd, F_SETFL, flags | O_NONBLOCK);
+	qemu_set_nonblock(fd);
 	/* Read-only to start; the write handler is armed on demand (see the note on
 	 * tcp_usb_callback) only while a write is pending, or the loop spins. */
 	qemu_set_fd_handler(fd, tcp_usb_read_callback, NULL, _state);
```

Runtime caveat (not a build blocker): the file classifies I/O errors
via `errno`, but Winsock reports via `WSAGetLastError()`. Connection
failures still return `-EIO` correctly; only fine-grained diagnostics
degrade. Follow-up work if the TCP bridge is used on Windows.

`setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one))` compiles
on Windows (pointer-type warning only, harmless with
`--disable-werror`).

## 3. Meson subproject pre-seed (robustness)

QEMU's meson fetches three subprojects from `gitlab.com`. That host
was unreachable from the Linux build VM (persistent TLS failures), so
the Linux build pre-seeded them from GitHub mirrors at the exact
revisions pinned in the `.wrap` files. GitHub runners can usually
reach gitlab.com, but pre-seeding is deterministic — do it anyway,
from the `qemu-ios/` source dir, before configure:

```sh
git clone --depth 1 https://github.com/qemu/keycodemapdb subprojects/keycodemapdb
git -C subprojects/keycodemapdb checkout f5772a62ec52591ff6870b7e8ef32482371f22c6
git clone --depth 1 https://github.com/qemu/berkeley-softfloat-3 subprojects/berkeley-softfloat-3
git -C subprojects/berkeley-softfloat-3 checkout b64af41c3276f97f0e181920400ee056b9c88037
git clone --depth 1 https://github.com/qemu/berkeley-testfloat-3 subprojects/berkeley-testfloat-3
git -C subprojects/berkeley-testfloat-3 checkout e7af9751d9f9fd3b47911f51a5cfd08af256a9ab
# replicate meson's patch_directory overlay:
cp subprojects/packagefiles/berkeley-softfloat-3/meson.build \
   subprojects/packagefiles/berkeley-softfloat-3/meson_options.txt \
   subprojects/berkeley-softfloat-3/
cp subprojects/packagefiles/berkeley-testfloat-3/meson.build \
   subprojects/packagefiles/berkeley-testfloat-3/meson_options.txt \
   subprojects/berkeley-testfloat-3/
```

(`dtc`, `libblkio`, `libvfio-user` wraps are never requested for this
target set — no action needed.)

## 4. Configure

From `qemu-ios/`, after patches and pre-seed (`shell: msys2 {0}`):

```sh
mkdir -p build && cd build
../configure --target-list=arm-softmmu \
  --enable-sdl --disable-cocoa \
  --disable-capstone --disable-slirp \
  --disable-werror --disable-opengl \
  --extra-ldflags="-lcrypto"
```

Flag rationale (differs from the Linux line in BUILD_LOG.md §4):
- `--disable-opengl`: QEMU's own OpenGL isn't needed (SDL2 display
  doesn't require it); avoids any GL detection surprises. The fork's
  GLES HLE independently falls back to `gles-host-stub.c` on Windows
  (Apple-frameworks deps, `required: false`).
- `--disable-cocoa`: accepted no-op off macOS, kept for parity.
- `--extra-ldflags="-lcrypto"`: the fork's AES/SHA1 code links
  OpenSSL directly (same as Linux). MSYS2's openssl package provides
  it; headers are on the default include path so no `--extra-cflags`
  is needed.
- PIE flags omitted: Windows executables get ASLR via
  `--dynamicbase` by default; let configure decide.
- No `--cross-prefix`: UCRT64 gcc is a native compiler.
- FFmpeg deliberately absent: `IT_HAVE_AVCODEC` stays unset and the
  amc patch covers the link (same as Linux). The
  `scripts/configure-patched-ffmpeg` flow is macOS-only; out of scope.

Expected configure summary: `sdl: enabled, slirp: disabled,
capstone: disabled, cocoa: disabled, opengl: disabled`.

## 5. Build

```sh
cd build
make -j$(nproc)
```

Expect ~10–20 min on a 4-vCPU runner (Linux reference: 10m20s on
2 vCPU; build tree ~1.5 GB — fine for GH runners).

## 6. Verify

```sh
./qemu-system-arm.exe --version
# expect: QEMU emulator version 11.0.3
./qemu-system-arm.exe -M ? | grep -iE "ipod|iphone|ipad"
# expect: iPhone-2G / iPhone-4 / iPod-Touch-1G / iPod-Touch-4G /
#         iPod-Touch / ipad1 / n18 / n88
./qemu-system-arm.exe -M iPod-Touch,bootrom=/nonexistent -display none
# expect clean error about the missing bootrom path, no crash
```

## 7. CI workflow skeleton

```yaml
name: Emulator CI (Windows)
on: [push, pull_request]
jobs:
  build:
    runs-on: windows-2025
    defaults:
      run:
        shell: msys2 {0}
    steps:
      - uses: actions/checkout@v4
      - name: Set up MSYS2 (UCRT64)
        uses: msys2/setup-msys2@v2
        with:
          msystem: UCRT64
          update: true
          install: >-
            base-devel git bison flex
            mingw-w64-ucrt-x86_64-toolchain
            mingw-w64-ucrt-x86_64-meson
            mingw-w64-ucrt-x86_64-ninja
            mingw-w64-ucrt-x86_64-pkgconf
            mingw-w64-ucrt-x86_64-python
            mingw-w64-ucrt-x86_64-glib2
            mingw-w64-ucrt-x86_64-pixman
            mingw-w64-ucrt-x86_64-SDL2
            mingw-w64-ucrt-x86_64-openssl
            mingw-w64-ucrt-x86_64-zlib
            mingw-w64-ucrt-x86_64-dtc
      - name: Apply patches
        run: |
          cd emulator/qemu-ios
          patch -p1 < ../amc-nonavcodec-fix.patch
          patch -p1 < ../fmss-win32-mmap.patch
          patch -p1 < ../tcp-usb-win32-sockets.patch
      - name: Pre-seed meson subprojects
        run: |
          cd emulator/qemu-ios
          # ... commands from §3 ...
      - name: Configure
        run: |
          cd emulator/qemu-ios
          mkdir -p build && cd build
          ../configure --target-list=arm-softmmu \
            --enable-sdl --disable-cocoa \
            --disable-capstone --disable-slirp \
            --disable-werror --disable-opengl \
            --extra-ldflags="-lcrypto"
      - name: Build
        run: |
          cd emulator/qemu-ios/build
          make -j$(nproc)
      - name: Verify
        run: |
          cd emulator/qemu-ios/build
          ./qemu-system-arm.exe --version
          ./qemu-system-arm.exe -M ? | grep -iE "ipod|iphone|ipad"
      - name: Upload emulator
        uses: actions/upload-artifact@v4
        with:
          name: qemu-system-arm-windows
          path: emulator/qemu-ios/build/qemu-system-arm.exe
```

## 8. Audit: fork code reviewed for Windows-hostile constructs

Searched all fork device models (`hw/arm/ipod_touch_*.c`, `hw/arm/s5l*.c`,
`hw/arm/ipad1.c`, `hw/arm/ipod-agent.c`, `hw/arm/it_iboot.c`,
`hw/arm/guest-*.c`, `hw/arm/mrvl8686.c`, `include/hw/arm/`):

| construct | found | disposition |
|---|---|---|
| `fork()`/`vfork()` | none | — |
| `epoll`/`eventfd`/`inotify`/`signalfd`/`timerfd` | none | — |
| `dlopen` | none | — |
| `execinfo.h`/`backtrace`, `getuid`, `uname`, `prctl`, `__linux__` | none | — |
| `__APPLE__` (h264, mpvd) | guarded, software fallback | compiles out on Windows |
| `mmap`/`munmap` (fmss.c) | **yes** | §2b patch |
| raw POSIX socket headers + `AF_UNIX` + `fcntl` (tcp_usb.c) | **yes** | §2c patch |
| Apple-frameworks meson deps (GLES) | `required: false` | stub on Windows |
| `contrib/` host tools, `tests/slice` (xcrun) | not in default build | out of scope |
| fork qtests (`tests/qtest/ipod-*-test.c`) | libqtest-based, portable | expected to build; verify in CI |

## 9. Known limitations / follow-ups (not CI blockers)

- **DLL-ification**: LightTouchMac loads the emulator as a dylib
  (`make-dylib-macos.sh`; see `DYLIB_RELINK_NOTES.md` for the Linux
  `.so` mechanics). The Windows equivalent (DLLs for Swift
  interop) is a separate later step; this plan produces
  `qemu-system-arm.exe`.
- **Packed-NAND fast path** disabled on Windows (§2b); directory
  fallback works, just slower. `MapViewOfFile` port is a small
  follow-up.
- **AF_UNIX bridge** unavailable on Windows (§2c); TCP `host:port`
  path retained.
- **FFmpeg**: skipped. Needed only for the h264-slice test path and
  hardware-decode acceleration; can be added later via a
  vcpkg/MSYS2 FFmpeg build (the `h264-chunk-er.patch` applies to
  FFmpeg 6.x/7.x per BUILD_LOG.md §7).
- `tests/gate.sh` is macOS-only (`xcrun`); not runnable on Windows.
