#!/bin/bash
# Build qemu-arm.dll on Windows (MSYS2/MINGW64) by relinking the
# qemu-system-arm objects, mirroring contrib/macos-app/make-dylib-macos.sh.
# Differences from the macOS script, all deliberate:
#   - The script does NOT live in qemu-src (it lives in lighttouch-emulator),
#     so SRC and BUILD are explicit arguments; they are resolved to absolute
#     paths before cd, so relative DEF paths still work.
#   - The extras patch (qemu-windows-extras.patch, same directory) must
#     already be applied to qemu-src: it stubs the two macOS-only extras
#     (key_mac's osx keymap, build_id's Mach-O UUID) on _WIN32. Without it
#     the link fails on undefined qemu_input_map_osx_to_qcode / dladdr.
#   - Meson uses @response-files for the link on Windows (long command
#     lines). The script expands one level of @rsp (except @*.syms, which
#     are exe-only and dropped, as on macOS) BEFORE rewriting. The macOS
#     script's @-dropping would delete the object list on Windows.
#   - No -undefined / --unresolved-symbols tolerance exists for Windows
#     DLLs: the link must resolve everything. The exe link line already
#     resolves everything except the patched extras, so this should hold;
#     if it does not, that is a Phase 1 block, not something to paper over
#     with an export-all flag.
#   - No .lib import library is produced: the consumer (the helper) loads
#     the DLL at runtime via LoadLibrary/GetProcAddress, which needs only
#     the DLL and its exports, not an import lib.
#   - No -fPIC: MinGW codegen needs none for DLL objects. No -pie flag
#     exists in the Windows configure (unlike the Linux .so notes).
#
#     make-dll-windows.sh <qemu-src-dir> <build-dir> <def-file>
#   The final link command is written to windows-link-dll.sh in BUILD for
#   debugging, as the macOS script writes macos-link-dylib.sh.
set -eu

if [ $# -ne 3 ]; then
    echo "usage: make-dll-windows.sh <qemu-src-dir> <build-dir> <def-file>" >&2
    exit 2
fi
SRC="$1"; BUILD="$2"; DEF="$3"
case "$SRC" in /*|*:*) ;; *) SRC="$PWD/$SRC" ;; esac
case "$BUILD" in /*|*:*) ;; *) BUILD="$PWD/$BUILD" ;; esac
case "$DEF" in /*|*:*) ;; *) DEF="$PWD/$DEF" ;; esac

OUT="$BUILD/qemu-arm.dll"
CC="${CC:-cc}"
HOST_CPU="x86_64"
TCG_HOST="i386"
DEP_CFLAGS="$(pkg-config --cflags glib-2.0 pixman-1)"

cd "$BUILD"

# Compile the app-facing pieces with the same include set the macOS script
# uses (minus -mmacosx-version-min, which is macOS-only).
for f in "$SRC/contrib/ios-app/qemu-ios-entry.c" \
         "$SRC/contrib/ios-app/qemu-ios-ui.c" \
         "$SRC/contrib/macos-app/qemu-macos-extras.c"; do
    o="$(basename "${f%.c}").o"
    "$CC" -c "$f" -o "$o" \
        -I. -I.. -Iqapi -Itrace -Iui \
        -I"$SRC/contrib/ios-app" -I"$SRC/contrib/macos-app" \
        $DEP_CFLAGS \
        -iquote . -iquote "$SRC" -iquote "$SRC/include" \
        -iquote "$SRC/host/include/$HOST_CPU" -iquote "$SRC/host/include/generic" \
        -iquote "$SRC/tcg/$TCG_HOST" \
        -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -std=gnu11 -O2
done

# Take ninja's own link line so this cannot drift from the real build.
# eval (as in the macOS script) so shell-quoted args tokenize correctly;
# the command comes from our own build dir, not untrusted input.
eval "LINK_CMD=($(ninja -t commands qemu-system-arm | tail -1))"
# Pass 1: expand one level of @response-files, dropping @*.syms.
# (CI paths contain no spaces, so naive whitespace splitting of .rsp
# files -- one arg per line or space-separated -- is safe here.)
LINK=()
for a in "${LINK_CMD[@]}"; do
    case "$a" in
        @*.syms) ;;  # exe-only symbol lists; the DLL uses its own .def
        @*)
            rsp="${a#@}"
            # RSP paths are relative to the build dir; we already cd'd there.
            for token in $(cat "$rsp"); do LINK+=("$token"); done
            ;;
        *) LINK+=("$a") ;;
    esac
done
# Pass 2: rewrite -- drop -o + value, swap main() for qemu_ios_main(),
# keep everything else (libs, flags, implib args) untouched.
ARGS=()
skip=0
for a in "${LINK[@]}"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in
        -o) skip=1 ;;                                   # drop the executable name
        *system_main.c.o)                               # main() -> qemu_ios_main()
            ARGS+=(qemu-ios-entry.o qemu-ios-ui.o qemu-macos-extras.o) ;;
        *) ARGS+=("$a") ;;
    esac
done
ARGS+=(-shared -o "$OUT" "$DEF")
printf '%q ' "${ARGS[@]}" > windows-link-dll.sh
echo >> windows-link-dll.sh
"${ARGS[@]}"
echo "built $OUT"
# Verify: the DLL must export the app ABI (spot-check the head symbol).
objdump -p "$OUT" | grep -q "qemu_ios_main" || {
    echo "qemu_ios_main missing from DLL exports" >&2; exit 1; }
