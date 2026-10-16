# Linux `.so` relink — findings from `contrib/macos-app/make-dylib-macos.sh`

Pinned commit `cb3595e8add3d9a3a55807186c6b8ff0ba338abe`. The ABI symbol list
itself is another worker's job; this file records only the *mechanics* a
Linux `make-so-linux.sh` must replicate.

## What the macOS script does

1. Compiles three app-facing sources with the *build's own compiler and flags*
   (read from `meson-info/intro-compilers.json` / `meson-info/intro-machines.json`):
   - `contrib/ios-app/qemu-ios-entry.c` — defines `qemu_ios_main()`, replaces
     `system/main.c`'s `main()`
   - `contrib/ios-app/qemu-ios-ui.c` — the `qemu_ios_ui_*` API
   - `contrib/macos-app/qemu-macos-extras.c` — macOS-specific additions
   (all three exist at the pinned commit).
2. Runs `ninja qemu-system-arm`, then steals ninja's exact link line:
   `ninja -t commands qemu-system-arm-unsigned | tail -1`.
3. Rewrites the link: drop `-o <exe>`; replace `*system_main.c.o` with the
   three entry objects; drop `@block.syms`/`@qemu.syms` response files;
   append `-dynamiclib -o libqemu-arm.dylib -install_name @rpath/libqemu-arm.dylib
   -Wl,-exported_symbols_list,macos-exports.syms -Wl,-undefined,dynamic_lookup`.
4. Writes `macos-exports.syms`: 62 `_qemu_ios_*` symbols, everything else private.
5. Links, `codesign -f -s -`, verifies with `nm -gU`.

## Linux equivalent: required translations

| macOS | Linux |
|---|---|
| `-dynamiclib` | `-shared` |
| `-install_name @rpath/libqemu-arm.dylib` | `-Wl,-soname,libqemu-arm.so` |
| `-Wl,-exported_symbols_list,macos-exports.syms` | `-Wl,--version-script=linux-exports.map` with `{ global: qemu_ios_*; local: *; };` (ELF: no leading underscores) |
| `-Wl,-undefined,dynamic_lookup` | `-Wl,--unresolved-symbols=ignore-all` |
| `codesign -f -s -` | not needed |
| `nm -gU` verification | `nm -gD --defined-only libqemu-arm.so` |
| ninja target `qemu-system-arm-unsigned` | `qemu-system-arm` (the `-unsigned` suffix is a macOS codesign artifact; Linux link rule is `c_LINKER_RSP`) |

## Linux-specific gotchas found in this build tree

1. **Drop `-pie`.** The documented Linux configure uses `--enable-pie`, so
   `LINK_ARGS` contains `-pie` and objects are compiled `-fPIE`. `-pie` is
   meaningless/contradictory with `-shared` and must be stripped from the
   relinked command. Note their macOS dylib flow configures `--disable-pie`
   (`scripts/configure-patched-ffmpeg`) while the macOS-app configure line in
   RUNNING.md doesn't — for the Linux `.so`, verify `-fPIE` objects link
   cleanly into the shared lib (usually fine on x86-64), otherwise build the
   dylib dir with `--disable-pie`. Open verification item.
2. **Replace `-Wl,--no-undefined`.** The exe link carries `-Wl,--no-undefined`;
   a `-shared` relink that leaves symbols for the host app to resolve needs
   `-Wl,--unresolved-symbols=ignore-all` instead (the macOS script's
   `-undefined dynamic_lookup` equivalent).
3. **`@block.syms`/`@qemu.syms` are absent here.** They are only added to
   `link_args` when `enable_modules` is true; this configure has `modules:
   disabled`, so they're order-only `link_depends` and never hit the link
   line. Keep the "drop `@*.syms`" rule for parity, but expect it to be a no-op.
4. **Compile entry objects with `-fPIC`.** The macOS script passes
   `-mmacosx-version-min=12.0`; Linux needs that dropped and `-fPIC` added
   (plus `-D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -std=gnu11 -O2`
   as on macOS). Same include set: `-I. -I.. -Iqapi -Itrace -Iui`,
   `-I contrib/ios-app`, `-iquote` for `.`, `SRC`, `SRC/include`,
   `SRC/host/include/<cpu>`, `SRC/host/include/generic`, `SRC/tcg/<tcg_host>`,
   and `pkg-config --cflags glib-2.0 pixman-1`.
5. **New Linux extras source needed.** `qemu-macos-extras.c` implements
   `qemu_ios_ui_key_mac()` via `qemu_input_map_osx_to_qcode`. The Linux port
   needs an equivalent (e.g. `qemu_ios_ui_key_linux()`) built on
   `qemu_input_map_linux_to_qcode` (evdev keycodes), which exists in
   `ui/input-keymap.c` at the pinned commit.
6. **Link line source:** `ninja -t commands qemu-system-arm | tail -1`, parsed
   the same way (response-file based `c_LINKER_RSP` rule: `cc -m64 @rsp`).

## Export list

Same 62 `qemu_ios_*` symbols as `macos-exports.syms` (leading underscores
removed); exact list and any additions are the ABI worker's call. On ELF the
version script `{ global: qemu_ios_*; local: *; };` covers future additions
automatically.
