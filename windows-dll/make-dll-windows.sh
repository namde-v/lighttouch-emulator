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
#     lines), but ninja generates the rsp ON DEMAND and it is gone by
#     the time this step runs (run 40788851368 step 14: the exe link
#     succeeded during Build, yet the build dir holds zero *.rsp).
#     Replaying the rsp-based link line by hand cannot work (branch b),
#     and enumerating the exe's object dir cannot either (branch b-v2,
#     run 40798501224 step 14: qemu-system-arm.exe.p holds zero .o --
#     the exe's objects live in the libraries' .p dirs via
#     extract_all_objects). So Pass 1 reads the object list from the
#     build graph itself: the LINK edge for qemu-system-arm.exe in
#     build.ninja, printing its input suffix histogram first (run
#     40807517166 step 14: meson on Windows uses .obj, and the .o-only
#     filter + .o-only swap silently dropped the bulk and the entry
#     objects). @*.syms are exe-only and dropped, as on macOS.
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
# CC may carry args: the workflow sets CC="ccache gcc". It must be split
# into an argv array -- quoting "$CC" as one word fails with
# "ccache gcc: command not found" (exit 127, run 40742705433 step 14).
# The unquoted expansion is intentional (trusted env var, our own workflow).
CC_ARGV=(${CC:-cc})
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
    "${CC_ARGV[@]}" -c "$f" -o "$o" \
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
# The ninja target is the OUTPUT FILENAME: qemu-system-arm.exe on Windows
# (the macOS script uses qemu-system-arm-unsigned for the same reason).
# The bare name 'qemu-system-arm' is NOT a target here -- ninja errors
# with 'unknown target' (run 40765284998 step 14).
eval "LINK_CMD=($(ninja -t commands qemu-system-arm.exe | tail -1))"
# Fail fast: a failing command inside $( ) does NOT trigger set -e, so
# without this check an unknown target yields an empty LINK_CMD and the
# script dies confusingly later at '-shared: command not found' (127).
if [ "${#LINK_CMD[@]}" -eq 0 ]; then
    echo "ninja link line empty for target qemu-system-arm.exe -- check the target name" >&2
    exit 1
fi
# Diagnostic (runs 40777790388 + 40788851368 step 14): print the link
# line's @-tokens and the build dir's rsp inventory. The rsp is gone by
# step-14 time (branch b, decided on run 40788851368), so this is a
# record of the link-line shape, not an input to Pass 1. Compact on
# purpose: the full link line runs to thousands of objects.
echo "Link-line response-file tokens:"
for a in "${LINK_CMD[@]}"; do
    case "$a" in @*) echo "  $a" ;; esac
done
echo "Response files present in build dir:"
ls -1 ./*.rsp 2>/dev/null || echo "  (no *.rsp in build dir)"
# Side observation (run 40798501224 step 14: exe .p dir holds zero .o):
# record what the exe object dir actually contains, without depending
# on it. Compact: first 20 entries + count.
echo "exe object dir listing:"
if [ -d qemu-system-arm.exe.p ]; then
    ls -1 qemu-system-arm.exe.p/ 2>/dev/null | head -20
    echo "  (count: $(ls -1 qemu-system-arm.exe.p/ 2>/dev/null | wc -l) entries)"
else
    echo "  (no qemu-system-arm.exe.p dir)"
fi
# Pass 1 (branch b-v2): do NOT expand @rsp -- the file is gone by now
# -- and do NOT enumerate object dirs (run 40798501224 step 14 proved
# the exe .p dir holds zero .o: the exe's objects live in the
# libraries' .p dirs via extract_all_objects). Instead, read the object
# list from the build graph: the LINK edge for qemu-system-arm.exe in
# build.ninja. The edge's explicit inputs ARE the link's objects, in
# link order; implicit (| ...) and order-only (|| ...) deps are cut.
# Parsing is lazy: it runs only if the link line actually carries the
# known rsp token, so a future rsp-free link line is not failed by a
# missing edge. Object order among .o files does not affect ld
# resolution (only archive order matters, and archives stay in
# link-line order). (CI paths contain no spaces.)
LINK=()
EXE_OBJS_DONE=0
EXE_OBJS=()
for a in "${LINK_CMD[@]}"; do
    case "$a" in
        @*.syms) ;;  # exe-only symbol lists; the DLL uses its own .def
        @qemu-system-arm.exe.rsp)
            # The known rsp: its content IS the exe link's object list,
            # read from build.ninja (ninja deletes the rsp after the
            # build, so the edge is the only faithful record of it).
            if [ "$EXE_OBJS_DONE" = 0 ]; then
                if [ ! -f build.ninja ]; then
                    echo "build.ninja not found in build dir (needed for the LINK-edge object list)" >&2
                    exit 1
                fi
                # Read ALL explicit edge inputs first (one per line),
                # then histogram + filter in bash. Filtering inside awk
                # hid the input shape on run 40798501224 step 14 (the
                # .o-only filter dropped the .obj bulk silently).
                mapfile -t EDGE_INPUTS < <(awk '
                    /^build qemu-system-arm\.exe:/ { cap=1 }
                    cap {
                      l=$0
                      while (l ~ / \$$/) { sub(/ \$$/, "", l); if ((getline nxt) <= 0) break; l = l " " nxt }
                      sub(/ \|.*$/, "", l)
                      n = split(l, f, /[ \t]+/)
                      start = 0
                      for (i=1; i<=n; i++) if (f[i] ~ /:$/) { start = i + 2; break }
                      if (start == 0) exit 1
                      for (i=start; i<=n; i++) print f[i]
                      exit
                    }' build.ninja)
                # Fail fast: without the object list the link would
                # silently produce a DLL missing every entry object
                # (run 40777790388 step 14: all 55 .def exports undefined).
                if [ "${#EDGE_INPUTS[@]}" -eq 0 ]; then
                    echo "no inputs on the qemu-system-arm.exe LINK edge in build.ninja" >&2
                    echo "qemu-system-arm edges (build, output, rule only):" >&2
                    awk '/^build qemu-system-arm/ { print "  " $1, $2, $3 }' build.ninja >&2
                    exit 1
                fi
                # Suffix histogram (run 40807517166 step 14): meson on
                # Windows uses .obj, NOT .o -- print the shape before
                # filtering, so a future suffix surprise is visible in
                # the log instead of silently dropping the bulk again.
                n_obj=0; n_o=0; n_a=0; n_lib=0; n_other=0
                main_found=0
                for t in "${EDGE_INPUTS[@]}"; do
                    case "$t" in
                        *.obj) n_obj=$((n_obj+1)) ;;
                        *.o) n_o=$((n_o+1)) ;;
                        *.a) n_a=$((n_a+1)) ;;
                        *.lib) n_lib=$((n_lib+1)) ;;
                        *) n_other=$((n_other+1)) ;;
                    esac
                    case "$t" in
                        *system_main.c.obj|*system_main.c.o) main_found=1 ;;
                    esac
                done
                echo "LINK edge inputs: total ${#EDGE_INPUTS[@]} (.obj $n_obj, .o $n_o, .a $n_a, .lib $n_lib, other $n_other)"
                echo "LINK edge inputs (first 10):"
                for ((i=0; i<${#EDGE_INPUTS[@]} && i<10; i++)); do
                    echo "  ${EDGE_INPUTS[$i]}"
                done
                if [ "$main_found" = 1 ]; then
                    echo "system_main object on LINK edge: yes"
                else
                    echo "system_main object on LINK edge: NO"
                fi
                # Filter: link objects are .obj (Windows meson) plus
                # .o (the run-7 straggler). Archives (.a/.lib) stay on
                # the LINK_CMD token side, as in the exe link.
                EXE_OBJS=()
                for t in "${EDGE_INPUTS[@]}"; do
                    case "$t" in *.obj|*.o) EXE_OBJS+=("$t") ;; esac
                done
                if [ "${#EXE_OBJS[@]}" -eq 0 ]; then
                    echo "no link objects (.obj/.o) on the qemu-system-arm.exe LINK edge" >&2
                    exit 1
                fi
                echo "exe objects: ${#EXE_OBJS[@]} link objects (.obj/.o) from the qemu-system-arm.exe LINK edge"
                EXE_OBJS_DONE=1
            fi
            LINK+=("${EXE_OBJS[@]}")
            ;;
        @*)
            # Any other @ token is unexpected: fail fast rather than
            # silently dropping part of the link (the run-40777790388
            # failure mode). This run shows exactly one @ token, but
            # do not assume that holds forever.
            echo "unexpected response-file token in exe link line: $a (only @qemu-system-arm.exe.rsp is expected)" >&2
            exit 1
            ;;
        *) LINK+=("$a") ;;
    esac
done
# Pass 2: rewrite -- drop -o + value, swap main() for qemu_ios_main(),
# keep everything else (libs, flags, implib args) untouched.
# Both suffixes: meson on Windows uses .obj (run 40807517166 step 14
# proved the .o-only swap never fired, so no entry object was linked
# and ld reported all 55 exports undefined with zero undefined refs).
ARGS=()
skip=0
swapped=0
for a in "${LINK[@]}"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in
        -o) skip=1 ;;                                   # drop the executable name
        *system_main.c.o|*system_main.c.obj)            # main() -> qemu_ios_main()
            ARGS+=(qemu-ios-entry.o qemu-ios-ui.o qemu-macos-extras.o)
            swapped=1 ;;
        *) ARGS+=("$a") ;;
    esac
done
# Fail fast on swap-miss: the entry objects define the DLL's ABI, so a
# link without them is doomed (run 40807517166 step 14) and must be a
# loud error, not a silent 55-error link.
if [ "$swapped" = 0 ]; then
    echo "system_main object not found in link inputs -- entry objects (qemu_ios_main) cannot be linked; refusing a doomed link" >&2
    exit 1
fi
ARGS+=(-shared -o "$OUT" "$DEF")
printf '%q ' "${ARGS[@]}" > windows-link-dll.sh
echo >> windows-link-dll.sh
"${ARGS[@]}"
echo "built $OUT"
# Verify: the DLL must export the app ABI (spot-check the head symbol).
objdump -p "$OUT" | grep -q "qemu_ios_main" || {
    echo "qemu_ios_main missing from DLL exports" >&2; exit 1; }
