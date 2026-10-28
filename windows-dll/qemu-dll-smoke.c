/* qemu-dll-smoke.c -- Phase 1 smoke proof for qemu-arm.dll.
 *
 * LoadLibrary the DLL, resolve three exports, call them WITHOUT booting a
 * VM, and print the results. Exit 0 only if every step succeeds.
 *
 *   qemu_ios_device_info_at -- valid BEFORE qemu_ios_main, no lock
 *     (qemu-ios-ui.h). Index 0 must exist: the arm-softmmu build compiles
 *     iPod/iPhone/iPad machines in, so NULL here means no machines were
 *     compiled in -- a real failure, not a smoke artifact.
 *   qemu_ios_build_id -- the loaded image's identity, or NULL when
 *     unavailable. NULL is a VALID result: it is the function's existing
 *     "identity unavailable" signal, and it is exactly what the Windows
 *     stub returns (no Mach-O UUID on Windows). The smoke checks that the
 *     symbol resolves and the call returns without faulting, not that an
 *     identity string exists.
 *   qemu_ios_api_version -- the ABI version constant (uint32_t).
 *
 * Build (MSYS2/MINGW64):  gcc qemu-dll-smoke.c -o qemu-dll-smoke.exe
 * Run:  ./qemu-dll-smoke.exe [path-to-qemu-arm.dll]   (default qemu-arm.dll)
 */
#include <windows.h>
#include <stdio.h>
#include <stdint.h>

/* First fields of QemuIosDeviceInfo (contrib/ios-app/qemu-ios-ui.h); only
 * these are read, so a partial struct is safe. */
typedef struct {
    const char *machine;        /* the -M name */
    const char *board;          /* the board ID iBoot reports */
    int screen_width;
    int screen_height;
    int screen_scale;
    int default_orientation;
} QemuIosDeviceInfo;

typedef const QemuIosDeviceInfo *(*device_info_at_fn)(int);
typedef const char *(*build_id_fn)(void);
typedef uint32_t (*api_version_fn)(void);

static const char *or_null(const char *s) { return s ? s : "(null)"; }

int main(int argc, char **argv)
{
    const char *path = (argc > 1) ? argv[1] : "qemu-arm.dll";
    HMODULE lib = LoadLibraryA(path);
    if (!lib) {
        fprintf(stderr, "smoke FAIL: LoadLibrary(%s) failed: %lu\n",
                path, (unsigned long)GetLastError());
        return 1;
    }
    device_info_at_fn device_info_at =
        (device_info_at_fn)(void *)GetProcAddress(lib, "qemu_ios_device_info_at");
    build_id_fn build_id =
        (build_id_fn)(void *)GetProcAddress(lib, "qemu_ios_build_id");
    api_version_fn api_version =
        (api_version_fn)(void *)GetProcAddress(lib, "qemu_ios_api_version");
    if (!device_info_at || !build_id || !api_version) {
        fprintf(stderr, "smoke FAIL: GetProcAddress failed: %lu "
                "(device_info_at=%p build_id=%p api_version=%p)\n",
                (unsigned long)GetLastError(),
                (void *)device_info_at, (void *)build_id, (void *)api_version);
        return 1;
    }
    const QemuIosDeviceInfo *info = device_info_at(0);
    if (!info) {
        fprintf(stderr, "smoke FAIL: device_info_at(0) returned NULL "
                "(no machines compiled in)\n");
        return 1;
    }
    printf("device_info_at(0): machine=%s board=%s screen=%dx%d scale=%d orientation=%d\n",
           or_null(info->machine), or_null(info->board),
           info->screen_width, info->screen_height,
           info->screen_scale, info->default_orientation);
    const char *id = build_id();
    printf("build_id=%s\n", id ? id : "(null: Windows stub, identity unavailable)");
    printf("api_version=%u\n", (unsigned)api_version());
    printf("smoke PASS\n");
    return 0;
}
