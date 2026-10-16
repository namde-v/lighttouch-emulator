# ABI Contract: LightTouchMac ↔ qemu-ios emulator library

How the Swift side consumes the emulator, pinned against
**qemu-ios @ `cb3595e8add3d9a3a55807186c6b8ff0ba338abe`**
(`~/workspace/lighttouch-cross/emulator/qemu-ios-abi`, read-only clone),
and upstream LightTouchMac (`~/workspace/lighttouch-cross/upstream`, read-only).

The emulator is consumed as **one shared library** — `libqemu-arm.dylib` on macOS,
`libqemu-arm.so` / `qemu-arm.dll` on the port targets — exporting a pure-C ABI
of `qemu_ios_*` symbols. The Swift side **never links it**: `LightTouchDevice/Qemu.swift`
`dlopen`s it at runtime and binds every entry point with `dlsym` + `@convention(c)`
function types (there is no bridging header and no `@_cdecl` on the Swift side).

ABI authorities, in order: `contrib/ios-app/qemu-ios-ui.h` (base),
`contrib/macos-app/qemu-macos-extras.h` (macOS-app additions),
`contrib/macos-app/make-dylib-macos.sh` (the exact 55-symbol export list).

---

## 1. Loading mechanism (`LightTouchDevice/Qemu.swift`, `main.swift`)

`Qemu.load()` tries candidates in order; the first that loads wins:

1. `LTM_QEMU_DYLIB` env var — **Debug builds only**.
2. `<helper-executable-dir>/../Frameworks/libqemu-arm.dylib` — the shipped app
   (`LightTouchDevice` lives in `Contents/MacOS`, so this is the app bundle's `Frameworks/`).
3. `@rpath/libqemu-arm.dylib` — development builds (`QEMU_BUILD_DIR` is on the helper's rpath).

Load: `dlopen(path, RTLD_NOW | RTLD_LOCAL)` — `RTLD_NOW` so a missing export fails
at load, not mid-session. Then the **API gate**: `qemu_ios_api_version()` returns
`major << 16 | minor`; the major must equal `Qemu.apiMajor` (2). A dylib from before
the version symbol existed reads as 0 and is refused. The real path is resolved via
`dladdr(qemu_ios_main)` → `dli_fname` (identifies the loaded image rather than the
path that was asked for), reported in the hello as `dylibPath`/`dylibModified`.

Binding: `sym(_:_:)` = `dlsym` + `unsafeBitCast` to a `@convention(c)` type;
**missing required symbol is `fatalError`**. `optionalSym` returns nil and the
caller degrades gracefully. All `lazy var`s, so binding happens on first use
(which is why `RTLD_NOW` matters: the load itself already proved every *export*
exists; `dlsym` per symbol then cannot fail for a correctly-built dylib).

Entry-point versioning rule (CONTRIBUTING.md): a **minor** bump only *adds* entry
points; a **major** bump removes/changes one, and a host built for another major
refuses the dylib. Optional symbols in the Swift binding and the dylib they
appeared in: `qemu_ios_ui_hardware_keyboard` (1.1), `qemu_ios_ui_backlight_level`
(2.1), `qemu_ios_ui_vibrator` (2.2), `qemu_ios_ui_modem_set/status/free`,
`qemu_ios_ui_net_restrict/lan`, `qemu_ios_ui_shutdown`, `qemu_ios_guest_package_report`,
`qemu_ios_gles_protocol`, `qemu_ios_build_id`. At the pinned commit
`QEMU_IOS_API_VERSION` = `(2u << 16) | 2u`.

**Only `LightTouchDevice` dlopens the library.** Nothing in `LightTouchMac/`,
`Packages/` or `LightTouchServices/` links or opens it. Tests stub it:
`tests/offline/.../HelperTests.swift` compiles a fake dylib exporting only
`qemu_ios_main` + `qemu_ios_api_version` with `/usr/bin/cc -dynamiclib`.

### Threading model and lifecycle

- `DeviceHost.boot(_:)` (once per process — QEMU cannot start twice in one process):
  `setenv` the config's environment → `qemu.attach(nil, nil)` → `status.qemuState = running`
  → spawns a dedicated `Thread` named `qemu-main`, **16 MiB stack**, `.userInteractive` QoS,
  running `qemu.main(argc, argv)` with `strdup`'d argv. When it returns, the helper
  records `exitCode`, sets `qemuState = exited`, and — via `onExit` — either reports
  `.qemuExited(rc)` to the app or `exit(rc)`.
- `qemu_ios_main` itself (`contrib/ios-app/qemu-ios-entry.c`): `qemu_init()` →
  force `autostart = 1` (so `-incoming` restores resume immediately) →
  `qemu_ios_ui_vm_started()` (attaches the display listener; consoles/AIO exist only now) →
  drop/reacquire BQL exactly as `system/main.c` does → `qemu_main_loop()` →
  `qemu_ios_ui_vm_stopped()` → `qemu_cleanup()` → return status.
- **All other entry points are app-thread safe**: each allocates a small struct and
  marshals the work onto the QEMU thread as a bottom half under the BQL
  (the one rule stated atop both headers). Callers that schedule bottom halves must
  check `qemu_ios_ui_ready()` first — before `qemu_init` the AioContext is NULL, and
  after the main loop returns nothing services them.
- **Never `pthread_exit` the thread that loaded the library before `qemu_ios_main`
  returns.** `main.swift` deliberately avoids `dispatchMain()` and parks the main
  thread in `CFRunLoopRun()`: the dylib's `rcu_init` constructor registered that
  thread as an RCU reader, so exiting it makes `call_rcu_thread` walk a freed TLS
  record (random heap corruption in `qemu_init`). The Linux/Windows ports must keep
  the loading thread alive the same way (a platform event loop, not thread exit).
- `signal(SIGPIPE, SIG_IGN)` in the helper (QEMU's own `os_setup_signal_handlers`
  later overrides SIGTERM handling — `DeviceHost.halt` notes this).
- Frame pump (`DeviceHost.tick`, `DispatchSourceTimer` on queue `"LightTouch.frames"`,
  `.userInteractive`): 60 Hz (120 with the experimental `refresh-hz` global; 30 under
  thermal pressure/Low Power Mode) while the app shows the screen and the guest display
  is on; else 4 Hz. Status fields refresh at 20 Hz live.
- Agent RPC (`AgentDispatcher`, queue `"LightTouch.agent"`): polls
  `qemu_ios_agent_result()` every 50 ms, routes by request id, frees each result.
- Audio (`AudioPump`, queue `"LightTouch.audio"`, `.userInitiated`): drains
  `qemu_ios_audio_capture_read` every 20 ms into `.audio` link events.
- Halt (`DeviceHost.halt`, also SIGTERM/SIGINT/vanished parent): wait ≤5 s for
  `qemu_ios_ui_ready()`, then `pause()` (flushes storage — the iPad IOP msyncs its
  NAND overlay on every VM stop), then `quit()`; wait ≤5 s for return, else `exit(1)`.
  Deliberately a hard halt, never a guest shutdown.

---

## 2. Build & export mechanism

`contrib/macos-app/make-dylib-macos.sh [build-dir]`:

1. Takes **ninja's own link line for `qemu-system-arm`** (so it can't drift), drops
   `system/main.c`'s object (whose `main()` wants the main thread for `CFRunLoopRun`)
   and substitutes three objects compiled with the build's own compiler/flags:
   `contrib/ios-app/qemu-ios-entry.c` (the `qemu_ios_main` entry),
   `contrib/ios-app/qemu-ios-ui.c` (base UI ABI),
   `contrib/macos-app/qemu-macos-extras.c` (macOS-app additions).
2. Links `-dynamiclib -o libqemu-arm.dylib -install_name @rpath/libqemu-arm.dylib`
   with `-Wl,-exported_symbols_list,macos-exports.syms` and
   `-Wl,-undefined,dynamic_lookup`; ad-hoc codesigns.
3. **The export list is exactly 55 symbols** (leading `_` in the file). Linux
   equivalent: the same 55 names (no underscore prefix) in a `--version-script` /
   `--dynamic-list`; Windows equivalent: a `.def` file with the same 55 names
   under `EXPORTS` (or `__declspec(dllexport)` on each definition).

Exported symbols (55) — `*` = bound by Swift (53), the other two are exported but unused:

```
qemu_ios_main *                     qemu_ios_ui_key_mac *
qemu_ios_device_info                qemu_ios_ui_rotate *
qemu_ios_device_info_at *           qemu_ios_ui_shake *
qemu_ios_ui_attach *                qemu_ios_ui_attitude *
qemu_ios_ui_frame *                 qemu_ios_ui_battery *
qemu_ios_ui_touch *                 qemu_ios_ui_usb_connection *
qemu_ios_ui_modem_set *             qemu_ios_ui_compass *
qemu_ios_ui_modem_status *          qemu_ios_ui_usb_charger
qemu_ios_ui_modem_free *            qemu_ios_ui_orientation *
qemu_ios_ui_touch2 *                qemu_ios_audio_capture_start *
qemu_ios_ui_button *                qemu_ios_audio_capture_read *
qemu_ios_ui_input_sequence *        qemu_ios_audio_capture_stop *
qemu_ios_ui_input_sequence_status * qemu_ios_ui_paste *
qemu_ios_ui_input_sequence_cancel * qemu_ios_agent_request *
qemu_ios_agent_cancel *             qemu_ios_agent_result *
qemu_ios_agent_free_result *        qemu_ios_agent_status *
qemu_ios_gles_contexts *           qemu_ios_guest_package_report *
qemu_ios_gles_protocol *           qemu_ios_build_id *
qemu_ios_api_version *             qemu_ios_ui_pause *
qemu_ios_ui_resume *               qemu_ios_ui_reset *
qemu_ios_ui_powerdown *            qemu_ios_ui_quit *
qemu_ios_ui_shutdown *             qemu_ios_ui_hardware_keyboard *
qemu_ios_ui_net_restrict *         qemu_ios_ui_net_lan *
qemu_ios_ui_ready *                qemu_ios_ui_storage_failed *
qemu_ios_ui_guest_shutdown_confirmed *  qemu_ios_ui_display_sleeping *
qemu_ios_ui_backlight_level *      qemu_ios_ui_vibrator *
qemu_ios_snapshot_save2 *          qemu_ios_snapshot_status *
qemu_ios_snapshot_resume *
```

Declared in the headers but **not exported** (dylib-internal): `qemu_ios_ui_battery_config`,
`qemu_ios_audio_capture_time`, `qemu_ios_ui_frame_size`, `qemu_ios_set_foreground`,
`qemu_ios_ui_vm_started`, `qemu_ios_ui_vm_stopped`, `qemu_ios_ui_cancel_input`,
`qemu_ios_ui_manual_touch2`.

---

## 3. Complete symbol table

C signatures are from `contrib/ios-app/qemu-ios-ui.h` / `contrib/macos-app/qemu-macos-extras.h`
at the pinned commit; Swift signatures are the `@convention(c)` types in
`LightTouchDevice/Qemu.swift`. Callers are the Swift files that use each binding
(`DeviceHost.swift` = the helper's per-VM driver; `Qemu.swift` = the loader).

### Lifecycle / introspection

| C symbol | C signature | Swift binding | Req | Callers | Purpose |
|---|---|---|---|---|---|
| `qemu_ios_main` | `int qemu_ios_main(int argc, char **argv)` | `(Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32` | req | `DeviceHost.boot` | Runs `qemu_init`, main loop, cleanup on the calling thread; never returns until the VM stops; call once per process on a background thread. argv is a full `qemu-system-arm` command line (`["LightTouchMac", "-M", machine, "-m", mem, "-display", "none", "-no-shutdown", …]`, `BootRecipe.swift:265`). |
| `qemu_ios_api_version` | `uint32_t qemu_ios_api_version(void)` | `() -> UInt32` | req (load gate) | `Qemu.init` | `major << 16 \| minor`; major must be 2. Pinned value `(2<<16)\|2`. |
| `qemu_ios_build_id` | `const char *qemu_ios_build_id(void)` | `() -> UnsafePointer<CChar>?` | opt | `DeviceHost.info` → `HelperInfo.buildID` | Hex of the loaded image's UUID (Mach-O `LC_UUID` walk; NULL if unavailable). **Platform-fragile** (see §6). |
| `qemu_ios_device_info_at` | `const QemuIosDeviceInfo *qemu_ios_device_info_at(int index)` | `(Int32) -> UnsafeRawPointer?` | req | `Qemu.machines` | Index-th machine the library runs; NULL past the last. Backs `machines` mode and `DeviceInfo` (board facts). `qemu_ios_device_info(name)` is exported but never called by Swift. |
| `qemu_ios_ui_attach` | `void qemu_ios_ui_attach(qemu_ios_frame_cb cb, void *opaque)` | `(UnsafeRawPointer?, UnsafeRawPointer?) -> Void` | req | `DeviceHost.boot` | Registers the display listener (safe before the VM has a console). Swift passes `(nil, nil)` — it never uses the frame callback, it **polls** `qemu_ios_ui_frame`. |
| `qemu_ios_ui_ready` | `bool qemu_ios_ui_ready(void)` | `() -> Bool` | req | `tick`, `refreshStatus`, `halt`, `AgentDispatcher` | True only while initialized and the main loop runs; gates bottom-half-scheduling calls. |
| `qemu_ios_ui_storage_failed` | `bool qemu_ios_ui_storage_failed(void)` | `() -> Bool` | req | `refreshStatus` | Session-latched host NAND I/O failure; safe to poll from any thread. |
| `qemu_ios_ui_guest_shutdown_confirmed` | `bool qemu_ios_ui_guest_shutdown_confirmed(void)` | `() -> Bool` | req | `refreshStatus` | True after the guest writes the final PMU power-off command. |
| `qemu_ios_ui_display_sleeping` | `bool qemu_ios_ui_display_sleeping(void)` | `() -> Bool` | req | `tick`, `refreshStatus` | Guest backlight state, independent of black framebuffer contents; drives the pump rate. |
| `qemu_ios_ui_backlight_level` | `int qemu_ios_ui_backlight_level(void)` | `() -> Int32` | opt (2.1) | `refreshStatus` → `status.backlightLevel` | Raw code the guest programmed into the backlight driver (0 = off, **-1** = board not decoded). |
| `qemu_ios_ui_vibrator` | `bool qemu_ios_ui_vibrator(uint64_t *pulses)` | `(UnsafeMutablePointer<UInt64>?) -> Bool` | opt (2.2) | `tick` → `status.vibrating`/`vibratorPulses` | Whether the vibration motor runs now; `*pulses` counts starts since process start (catches buzzes shorter than the poll). False on machines without one. |

`QemuIosDeviceInfo` (mirrored by Swift `QemuDeviceInfoC`; layout verified
field-for-field, 56 bytes on LP64 *and* LLP64 — `bool` is 1 byte, `int` 4, pointers 8):

```c
typedef struct {
    const char *machine;   /* -M name */          const char *board; /* e.g. "n72ap" */
    int screen_width, screen_height, screen_scale; int default_orientation; /* 0 portrait, 1 landscape */
    bool has_cellular, has_usb_host, has_compass, has_usb_charger;
    int panel_min, panel_max_width, panel_max_height, panel_width_step, panel_max_pixels;
} QemuIosDeviceInfo;
```

Machine table (`qemu-ios-ui.c`, 8 entries): `iPod-Touch`/`n72ap` 320×480,
`iPod-Touch-1G`/`n45ap`, `iPhone-2G`/`m68ap` (cellular), `n18`/`n18ap`,
`n88`/`n88ap` (cellular, compass), `ipad1`/`k48ap` 1024×768 landscape
(usb-host, compass, charger), `iPod-Touch-4G`/`n81ap` 640×960 @2x (usb-host),
`iPhone-4`/`n90ap` 640×960 @2x (cellular, usb-host, compass).

### Display frame

| C symbol | C signature | Swift binding | Req | Callers | Purpose |
|---|---|---|---|---|---|
| `qemu_ios_ui_frame` | `bool qemu_ios_ui_frame(const void **pixels, int *width, int *height, uint64_t *serial)` | `(UnsafeMutablePointer<UnsafeRawPointer?>, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<UInt64>) -> Bool` | req | `DeviceHost.tick` | Newest frame as **tightly packed BGRA, without a copy**. `serial` is in/out: pass the last seen; returns false (touching nothing) when nothing is newer. See §4 for ownership. |

### Input: touch / buttons / keys / sensors

| C symbol | C signature | Swift binding | Req | Callers | Purpose |
|---|---|---|---|---|---|
| `qemu_ios_ui_touch` | `void qemu_ios_ui_touch(int slot, int phase, double nx, double ny)` | `(Int32, Int32, Double, Double) -> Void` | req | `perform(.touch)` | Legacy absolute-pointer path (deliberately not QEMU's multi-touch events). `phase`: `QEMU_IOS_TOUCH_BEGIN=0`/`UPDATE=1`/`END=2` (mirrored as `TouchPhase` in `DisplayView.swift:451`). `nx, ny` normalized 0..1, y down. |
| `qemu_ios_ui_touch2` | `void qemu_ios_ui_touch2(int phase, double nx, double ny)` | `(Int32, Double, Double) -> Void` | req | `perform(.touch2)` | Second finger for pinch/rotate on the multi-touch path (slot 1, distinct tracking id). Same phase constants. |
| `qemu_ios_ui_button` | `void qemu_ios_ui_button(int button, bool down)` | `(Int32, Bool) -> Void` | req | `perform(.button)` | Press/release as separate calls. `QEMU_IOS_BUTTON_HOME=0`, `_POWER=1`, `_VOLUME_UP=2`, `_VOLUME_DOWN=3` (mirrored as `DeviceInput.Button`, `DeviceInput.swift:33`). |
| `qemu_ios_ui_key_mac` | `void qemu_ios_ui_key_mac(int mac_keycode, bool down)` | `(Int32, Bool) -> Void` | req | `perform(.key)` | Host key by **macOS virtual keycode** (`NSEvent.keyCode`/`kVK_*`) via QEMU's generated `qemu_input_map_osx_to_qcode`; unmapped, Command and Control are ignored. **Platform-fragile** — Linux/Windows need their own keycode map (see §6). |
| `qemu_ios_ui_hardware_keyboard` | `bool qemu_ios_ui_hardware_keyboard(bool attached)` | `(Bool) -> Bool` | opt (1.1) | `handle(.hardwareKeyboard)` | Attach/detach emulated USB keyboard (`usb-kbd` on `usb-bus.0`); false where the machine has no `usb-bus.0`. |
| `qemu_ios_ui_rotate` | `void qemu_ios_ui_rotate(bool clockwise)` | `(Bool) -> Void` | req | `perform(.rotate)` | Edge-triggered, self-releasing (sends the Meta+Left/Right chord in one shot). |
| `qemu_ios_ui_shake` | `void qemu_ios_ui_shake(void)` | `() -> Void` | req | `perform(.shake)` | Shake gesture (machine property `accel-shake`). |
| `qemu_ios_ui_attitude` | `void qemu_ios_ui_attitude(double pitch_deg, double roll_deg, int pose)` | `(Double, Double, Int32) -> Void` | req | `perform(.attitude)` | Degrees, right-edge-down / top-edge-away positive; `pose` 0 upright, 1 flat (`DeviceInput.MotionPose`). |
| `qemu_ios_ui_orientation` | `bool qemu_ios_ui_orientation(int value)` | `(Int32) -> Bool` | req | `handle(.orientation)` | Sets the accelerometer orientation vector outright (1–6), not stepped. |
| `qemu_ios_ui_compass` | `bool qemu_ios_ui_compass(int heading_deg)` | `(Int32) -> Bool` | req | `handle(.compass)` | Magnetic heading 0–359 (machine `compass-heading`); false where the machine has none. |
| `qemu_ios_ui_paste` | `void qemu_ios_ui_paste(const char *utf8)` | `(UnsafePointer<CChar>) -> Void` | req | `perform(.paste)` | Queue UTF-8 text for the guest pasteboard (machine property `pasteboard`). |
| `qemu_ios_ui_battery` | `bool qemu_ios_ui_battery(int level, int charging)` | `(Int32, Int32) -> Bool` | req | `handle(.battery)` | Target capacity 0–100; charging 0 auto, 1 on, 2 off. Returns whether queued. |
| `qemu_ios_ui_usb_connection` | `bool qemu_ios_ui_usb_connection(bool attached)` | `(Bool) -> Bool` | req | `handle(.usbConnection)` | USB cable attach/detach. |
| `qemu_ios_ui_input_sequence` | `bool qemu_ios_ui_input_sequence(uint64_t id, size_t count, const int64_t *at_ms, const int32_t *kind, const int32_t *value, const int32_t *phase, const double *x, const double *y)` | `(UInt64, UInt, UnsafePointer<Int64>, UnsafePointer<Int32>, UnsafePointer<Int32>, UnsafePointer<Int32>, UnsafePointer<Double>, UnsafePointer<Double>) -> Bool` | opt | `handle(.inputSequence)` | Host-authored button/touch automation in **guest virtual ms** (not wall time); arrays have `count` elements; transitions must be balanced and ordered; a new submission cancels the prior one; manual input cancels it too. Immediate return = queued, not executed. Not part of a guest snapshot. (`VirtualInputEvent`: kind 0 = button(value 0–3, phase 0/1), kind 1 = touch; ≤256 events, ≤600 s.) |
| `qemu_ios_ui_input_sequence_status` | `int qemu_ios_ui_input_sequence_status(uint64_t id)` | `(UInt64) -> Int32` | opt | `handle(.inputSequenceStatus)` | `QEMU_IOS_INPUT_UNKNOWN=0`, `_RUNNING=1`, `_DONE=2`, `_CANCELLED=3`, `_REJECTED=4`. |
| `qemu_ios_ui_input_sequence_cancel` | `void qemu_ios_ui_input_sequence_cancel(uint64_t id)` | `(UInt64) -> Void` | opt | `handle(.inputSequenceCancel)` | Releases only owned signals, even while paused. |

### Modem (radio boards; all optional — dylibs before the Carrier panel lack them)

| C symbol | C signature | Swift binding | Callers | Purpose |
|---|---|---|---|---|
| `qemu_ios_ui_modem_set` | `bool qemu_ios_ui_modem_set(const char *property, const char *value)` | `(UnsafePointer<CChar>, UnsafePointer<CChar>) -> Bool` | `handle(.modemSet)` | Write one modem property from its string form on the QEMU thread. Properties: `carrier`, `mcc-mnc`, `registered`, `sim-present`, `signal-dbm`, `incoming-call`, `remote-answer`, `remote-hangup`, `incoming-sms`, `gps-fix` (where the modem has GPS). False = no modem / no such property; a property's own refusal shows as `"error"` in the next status. Boot also passes them as `-global ios-baseband.<name>=<value>` (`CarrierSettings.globals`). |
| `qemu_ios_ui_modem_status` | `char *qemu_ios_ui_modem_status(void)` | `() -> UnsafeMutablePointer<CChar>?` | `handle(.modemStatus)` | **Owned** JSON object of the modem state as of the last refresh — this call schedules a refresh, so poll it; NULL without a modem. **Free with `qemu_ios_ui_modem_free`.** |
| `qemu_ios_ui_modem_free` | `void qemu_ios_ui_modem_free(char *status)` | `(UnsafeMutablePointer<CChar>?) -> Void` | `handle(.modemStatus)` | Frees the `modem_status` string. |

### Networking (optional — older dylibs leave networking restricted)

| C symbol | C signature | Swift binding | Callers | Purpose |
|---|---|---|---|---|
| `qemu_ios_ui_net_restrict` | `void qemu_ios_ui_net_restrict(const char *id, bool restrict_)` | `(UnsafePointer<CChar>, Bool) -> Void` | `perform(.netRestrict)` | Flip a running user netdev's slirp `restrict` flag in place. Swift passes `"wifi0"`; NULL/empty id = the only user stack. `restrict=false` opens outbound networking without a link event (guest keeps Wi-Fi association + DHCP lease). |
| `qemu_ios_ui_net_lan` | `void qemu_ios_ui_net_lan(const char *id, bool allowed)` | `(UnsafePointer<CChar>, Bool) -> Void` | `perform(.netLocalNetwork)` | Allow/refuse guest traffic to the host's local networks on one (or, for NULL/empty id, every) user netdev. Swift passes `""` = every netdev (`wifi0`, an iPhone's `cell0`). Boot with `-netdev user,...,lan=off` to start refused. |

### Machine control

| C symbol | C signature | Swift binding | Req | Callers | Purpose |
|---|---|---|---|---|---|
| `qemu_ios_ui_pause` | `void qemu_ios_ui_pause(void)` | `() -> Void` | req | `machine(.pause)`, `halt` | `vm_stop`; storage is flushed before a later quit. |
| `qemu_ios_ui_resume` | `void qemu_ios_ui_resume(void)` | `() -> Void` | req | `machine(.resume)` | |
| `qemu_ios_ui_reset` | `void qemu_ios_ui_reset(void)` | `() -> Void` | req | `machine(.reset)` | |
| `qemu_ios_ui_powerdown` | `void qemu_ios_ui_powerdown(void)` | `() -> Void` | req | `machine(.powerdown)`, `machine(.shutdown)` fallback | Board's power-off gesture. |
| `qemu_ios_ui_shutdown` | `int qemu_ios_ui_shutdown(void)` | `() -> Int32` | opt | `machine(.shutdown)` | Guest powers itself off, as the slider does. **1**: the guest agent was asked to halt (`reboot2(RB_HALT)`; reply id `"qemu-ios-shutdown"`); **2**: no live agent (iPhone OS 1.x) → board's power-off gesture; **0**: nothing started. Completion = `qemu_ios_ui_guest_shutdown_confirmed()`. |
| `qemu_ios_ui_quit` | `void qemu_ios_ui_quit(void)` | `() -> Void` | req | `machine(.quit)`, `halt`, headless/oneshot | Ends the main loop; `qemu_ios_main` then returns. |

### Snapshots

| C symbol | C signature | Swift binding | Req | Callers | Purpose |
|---|---|---|---|---|---|
| `qemu_ios_snapshot_save2` | `void qemu_ios_snapshot_save2(const char *path)` | `(UnsafePointer<CChar>) -> Void` | req | `perform(.snapshotSave)` | Save machine to `path` for a later `-incoming file:<path>` restore. **Asynchronous**; sets status RUNNING on the calling thread before scheduling; the guest is stopped as a side effect. |
| `qemu_ios_snapshot_status` | `QemuIosSnapshotStatus qemu_ios_snapshot_status(char *errbuf, unsigned long errlen)` | `(UnsafeMutablePointer<CChar>, UInt) -> Int32` | req | `handle(.snapshotStatus)` (512-byte buffer) | 0 `IDLE` / 1 `RUNNING` / 2 `DONE` / 3 `FAILED`; on failure `errbuf` holds the reason. Swift surfaces `.snapshot(status:error:)` with the message only when status == 3. **Note**: `unsigned long` is 64-bit on LP64 but 32-bit on Windows LLP64 — bind as `UInt32` on Windows or change the C type. |
| `qemu_ios_snapshot_resume` | `void qemu_ios_snapshot_resume(void)` | `() -> Void` | req | `perform(.snapshotResume)` | Resume the vCPU after a completed save, without touching foreground state. |

### Guest agent RPC

Wire format: request = `"<id> <op> <args>\n<base64 body>"`; result = owned
`"<id> <status>\n<base64 body>"` or NULL. Always free non-NULL results with
`qemu_ios_agent_free_result`. Used for guest tools (`it_agent`, `it_prefs`, `sbdlicon`,
`itstatus`, media upload…).

| C symbol | C signature | Swift binding | Req | Callers | Purpose |
|---|---|---|---|---|---|
| `qemu_ios_agent_request` | `bool qemu_ios_agent_request(const char *request)` | `(UnsafePointer<CChar>) -> Bool` | req | `AgentDispatcher.submit` | Queue one request; false = queue full/unavailable. `deadline <= 0` submits fire-and-forget (used for the halt request). |
| `qemu_ios_agent_cancel` | `void qemu_ios_agent_cancel(const char *id)` | `(UnsafePointer<CChar>) -> Void` | req | `AgentDispatcher.cancel` | Stop pending work; an executed mutation can't be undone. |
| `qemu_ios_agent_result` | `char *qemu_ios_agent_result(void)` | `() -> UnsafeMutablePointer<CChar>?` | req | `AgentDispatcher.poll` | Next completed result (owned) or NULL. |
| `qemu_ios_agent_free_result` | `void qemu_ios_agent_free_result(char *result)` | `(UnsafeMutablePointer<CChar>?) -> Void` | req | `AgentDispatcher.poll` | Frees an agent result. |
| `qemu_ios_agent_status` | `int qemu_ios_agent_status(void)` | `() -> Int32` | req | `refreshStatus` → `status.agentStatus` | 0 absent/not running, 1 alive, 2 stale. |

### GL / guest package

| C symbol | C signature | Swift binding | Req | Callers | Purpose |
|---|---|---|---|---|---|
| `qemu_ios_gles_contexts` | `int qemu_ios_gles_contexts(void)` | `() -> Int32` | req | `tick`→`status.glesContexts`, headless dumps | Live host GL contexts (atomic renderer count; 0 unless ready). **A snapshot cannot include live host GL contexts** — the app refuses snapshot with any live. |
| `qemu_ios_gles_protocol` | `int32_t qemu_ios_gles_protocol(int64_t *serial)` | `(UnsafeMutablePointer<Int64>?) -> Int32` | opt | `refreshStatus` → `status.glesProtocol/glesSerial` | The GL shim's wire protocol from `QC_GLES_HELLO` + its package serial; 0 (today's wire) when no hello since last reset. |
| `qemu_ios_guest_package_report` | `bool qemu_ios_guest_package_report(int64_t *serial, int32_t *result)` | `(UnsafeMutablePointer<Int64>?, UnsafeMutablePointer<Int32>?) -> Bool` | opt | `refreshStatus`, `DeviceHost.init` (`status.guestPackageSupported`) | `it_boot`'s last `QC_PKG_REPORT` since the guest last reset: current serial + result code (`it_boot.c` `R_*`; negative = install failed, previous package kept running). False = no report yet. |

### Audio capture

Guest output capture through QEMU's mixer (never the host microphone).

| C symbol | C signature | Swift binding | Req | Callers | Purpose |
|---|---|---|---|---|---|
| `qemu_ios_audio_capture_start` | `uint64_t qemu_ios_audio_capture_start(void)` | `() -> UInt64` | req | `AudioPump.start` | Begin a capture generation; **0** = device not ready. |
| `qemu_ios_audio_capture_read` | `int qemu_ios_audio_capture_read(uint64_t generation, void *buffer, int capacity, double *seconds)` | `(UInt64, UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<Double>?) -> Int32` | req | `AudioPump.drain` | **44100 Hz stereo S16LE** packets; `capacity` must be ≥ 16384. Returns bytes read; **0** = empty (`*seconds` = capture time if active else −1; `seconds >= 0` on empty marks silence through that time); **−1** = failed/expired generation or bad args. Queued packets stay readable after `stop`, until the next generation starts. |
| `qemu_ios_audio_capture_stop` | `void qemu_ios_audio_capture_stop(uint64_t generation)` | `(UInt64) -> Void` | req | `AudioPump.stop/finish` | Stop; already-queued packets are still delivered (helper drains up to 1 s), then `.audioEnded`. |

---

## 4. Data paths in detail

### Display frames: dylib-owned BGRA, borrowed by the helper, copied to IOSurface

1. The dylib registers a `DisplayChangeListener` (`ios_dcl_ops`, `dpy_name = "ios"`)
   on console 0 once `qemu_ios_main` → `qemu_ios_ui_vm_started()` runs. The guest boots
   with `-display none`; the console surface is 32-bit.
2. On each refresh, `ios_capture()` copies the QEMU `DisplaySurface` into one of
   **3 rotating buffers** (`ios.buf[3]`, `g_malloc0`'d by the dylib — the ONLY copy on
   the emulator side; handing QEMU's surface directly would be a use-after-free under
   `dpy_gfx_switch`). Rows are `memcpy`'d as `w*4` bytes: the surface is already
   tightly packed **BGRA** (alpha ignored — the iPod framebuffer leaves it 0).
   Unchanged frames keep the old serial (no publish).
3. `qemu_ios_ui_frame(&pixels, &w, &h, &serial)`: under `ios.frame_lock`, if
   `ios.published < 0` or the serial matches, returns false touching nothing;
   else hands out `ios.buf[ios.published]` **without copying**. The pointer stays
   valid for the next few frames (3 buffers); **never free it, never hold it**.
4. `DeviceHost.tick()` copies it synchronously into the `FrameRingWriter`'s
   IOSurface (`FrameRingWriter.copy(pixels, width:height:into:)` — tightly packed
   BGRA rows into padded surface rows; `SharedStatus.swift:263`), publishes the
   surface to the ring, and only then advances `frameSerial`. The app reads frames
   from the IOSurface ring via Mach ports (`DeviceRendezvous.sendHello(... surfaces:)`).
   A frame that found no free surface is retried next tick (the emulator republishes
   only changed pixels).

So: **the dylib allocates and owns the pixel buffers; the helper borrows the newest
and copies it into IOSurface shared memory; the app renders from the ring.**
On Linux/Windows the copy target changes (Phase 2/3 already redesigned the
Apple-only shared-memory transport as POSIX shared memory), but the dylib side —
hand out a borrowed BGRA pointer under a lock — is portable as-is. The one thing to
verify per platform: the `-display none` console surface really is 32-bit BGRA
(`ios_capture` assumes 4 bytes/pixel unconditionally).

### Audio: generation-scoped packet queue, helper-owned buffer

`AudioPump` (20 ms timer): `qemu_ios_audio_capture_start()` → nonzero generation →
loop `qemu_ios_audio_capture_read(generation, 16 KiB buffer, 16384, &seconds)` up to
32× per drain; each packet emitted as `.audio(generation:seconds:pcm:)` link event
(`pcm` = `Data` copied out of the helper's buffer). `n < 0` ends the capture as
failed; `n == 0 && seconds < 0` or a 0-byte packet ends the drain round.
`stop(generation)` → `qemu_ios_audio_capture_stop(g)` → 1 s drain of leftovers →
`.audioEnded`. Format is fixed: **44100 Hz, stereo, S16LE**; mixer packets of
exactly 16384 bytes capacity. The dylib owns the 128-packet queue per generation
under its own mutex — no BQL/`ready()` needed.

### Input injection

- Touch/buttons/keys/shake/attitude/paste: direct `void` calls; the C side wraps each
  in a bottom half onto the QEMU thread (`qemu_input_event_*` / machine properties).
  `qemu_ios_ui_touch` deliberately uses the **legacy absolute-pointer + button**
  path (the multi-touch commit ordering drops presses); `touch2` uses the real
  multi-touch path for the second finger.
- `qemu_ios_ui_key_mac` takes **macOS virtual keycodes** (app sends
  `NSEvent.keyCode`, e.g. 56 = Shift; `DeviceInput.swift:89-94`).
- Automation: `qemu_ios_ui_input_sequence` queues timed events executed on the
  guest's virtual clock; polled via `_status`, cancellable via `_cancel`.
- Everything else (agent RPC, modem, netdev flags, snapshots) is covered in §3.

---

## 5. Guest artifacts (`contrib/export-guest-artifacts.sh`)

`scripts/build-guest-tools.sh` is a thin caller of
`qemu-ios contrib/export-guest-artifacts.sh OUT [QEMU-BUILD-DIR]`.
It builds the guest payloads from the qemu-ios checkout (never shipping stale
tracked binaries) and stages, into a **new** `OUT/` directory:

- `guest-tools/` — the iPod set the app **uploads through the guest agent** at
  runtime (`itmedia`, `itphoto`, `it_agent`, `it_typein.dylib`, `itstatus`,
  `itproxy`, `ittrust`, `itorient`, `ithalt`, `sbdlicon`, `com.qemu.it-agent.plist`).
- `ipad-guest-tools/` — the flat directory **firmwarekit** reads (`--guest-tools`;
  `SystemEdits.Helpers`): `it_pbd`, `it_prefs`, `it_msmquiet.dylib`, `it_seal`,
  `it_keybag`, `it_gltest`, `libappsync.dylib`, `appsync-launch`, the fat
  `OpenGLES` GL front end + `gles-names.h` (the wire name table), `OpenGLES-1x` +
  `opengles-1x.exports`, `armv6.itpack` / `armv7.itpack` (guest-package, `VERSION`
  serial), `sblaunch`, `sbdlicon`, `it_agent`, `it_typein.dylib`,
  `it_keybag-armv6`, `-legacy` (armv7-on-3.0) variants, and the
  `com.qemu.*.plist` launchd plists.
- `macos-app/entitlements.plist`; `include/ios-app/` + `include/macos-app/` —
  the headers the helper compiles against.
- `dylib/libqemu-arm.dylib` — only when `QEMU-BUILD-DIR` is given
  (runs `make-dylib-macos.sh` on that configured build).
- `manifest.json` (schema 1): source commit/branch/dirty, `guest_package`
  serial + version, the SDK paths, signer, sha256 of every staged file, and the
  build inputs. `Vendor.guest()` (`Packages/BuildTools/.../Vendor.swift:234`)
  requires `manifest.json` present, `guest_package.serial >= 16`
  (`guestPackageMinSerial`), and every expected file present
  (`ipodTools = [itmedia, itphoto]` under `guest-tools/`; the 17-entry
  `guestTools` list under `ipad-guest-tools/`).
- `build/` — the guest-package build tree (sources copy + logs).

Build-time requirements of the export script itself: `ARMV6_SDK`
(iPhoneOS3.1.3.sdk), `IPAD_SDK` (iPhoneOS3.2.sdk), `ldid`, `jq`, `xcrun`, `file`,
`lipo` — i.e. it currently only runs on macOS with the old iOS SDKs.

What the Swift core expects **at runtime**:

- `Resources/Guest/guest.aar` in the app bundle — an **Apple Archive** packing
  `guest-tools/` (the `ipad-guest-tools` set, renamed), `developer-tools/`,
  `tools/` (`itmedia`, `itphoto`), and `developer-disk-images/`
  (`Vendor.swift:505-524`). Packed as one archive so codesign/notary see no
  nested code in Resources.
- `GuestArchive.unpacked(resources:)` (`Packages/FirmwareKit/.../GuestArchive.swift`)
  unpacks it **once per archive** into the user's caches:
  `~/Library/Caches/gold.samhenri.LightTouchMac/Guest/<sha256-8>/` with a
  `.complete` marker; `Bundled.guestRoot` points there (nil in dev builds without it).
- firmwarekit's device `create` bakes `--guest-tools <guestRoot>` into the device
  image at prepare time (`Vendor.swift:347-363`); the running guest gets further
  payloads via the `it_agent` upload path (`Bundled.toolsDirectory` =
  `<guestRoot>/tools`).
- Boot ROMs: `Resources/Device/` (`bootrom_240_4`, `ipod1g/bootrom_s5l8900`),
  overridable via `LTM_FILES`, falling back to the dev checkout's `qemu-ios-files`
  (`Bundled.filesRoot`).

---

## 6. Platform-fragile ABI surface

These are the spots where a mechanical recompile is **not** enough; each needs a
deliberate per-platform decision in Phase 5/6:

1. **`qemu_ios_ui_key_mac`** — takes macOS virtual keycodes through QEMU's generated
   `qemu_input_map_osx_to_qcode`. Linux (evdev) and Windows (VK) hosts need their own
   map. Options: add `qemu_ios_ui_key_linux(int evdev_code, bool down)` /
   `qemu_ios_ui_key_win(...)` entry points (minor ABI bump), or translate to
   `QKeyCode` on the Swift side and add a `qemu_ios_ui_key_qcode` entry. Either way
   the Swift `LinkCommand.key(macKeyCode:)` producer must change per platform.
2. **`qemu_ios_build_id`** — walks Mach-O load commands (`mach_header_64`,
   `LC_UUID`) via `dladdr`. Linux: parse the ELF `NT_GNU_BUILD_ID` note from
   `dladdr`'s `dli_fbase`; Windows: PE debug-directory GUID/codeview. It's
   optional (NULL allowed), so a stub returning NULL also satisfies the contract.
3. **`qemu_ios_snapshot_status`'s `unsigned long errlen`** — 64-bit on LP64
   (macOS/Linux), 32-bit on Windows LLP64. The Swift binding passes `UInt(512)`.
   Use a fixed-width type in the C signature or bind `UInt32` on Windows.
   (Same class of issue: `size_t count` in `qemu_ios_ui_input_sequence` is 64-bit
   on both Win64 and LP64, so it's fine.)
4. **Main-thread lifetime** (`main.swift: parkMainThread`) — the dylib's `rcu_init`
   constructor registers the loading thread as an RCU reader; `pthread_exit`ing it
   corrupts QEMU's RCU TLS. The Linux `.so` has the same constraint (liburcu /
   QEMU's `util/rcu.c`); keep the loading thread in a run loop, never exit it.
5. **`dlopen` candidates** — `../Frameworks/libqemu-arm.dylib` and `@rpath` are
   Mach-O concepts. Linux: `$ORIGIN/../lib/libqemu-arm.so` + rpath + `LTM_QEMU_DYLIB`
   override; Windows: app dir / `PATH` + override env for `LoadLibraryEx`.
   `RTLD_NOW|RTLD_LOCAL` maps to default `dlopen` flags on Linux; on Windows every
   `GetProcAddress` must be null-checked (no load-time failure equivalent).
6. **`Qemu.swift`'s `dladdr`/`Dl_info` path resolution** — `dladdr` exists on glibc;
   on Windows the equivalent is `GetModuleHandleEx` + `GetModuleFileNameW`.
   (Or just rely on `qemu_ios_build_id` + the requested path.)
7. **Guest-artifact packaging uses Apple-only tooling**: `guest.aar` is an
   **Apple Archive** unpacked with the `AppleArchive` framework
   (`GuestArchive.swift`) — macOS-only. The Linux/Windows ports must either ship
   the archive pre-unpacked, or swap in a portable archive format + unpacker.
   Likewise `export-guest-artifacts.sh` needs `xcrun`, `lipo`, `ldid` and the
   iPhoneOS 3.x SDKs — the ARM guest binaries can be built once on macOS and
   shipped as data, but the script itself doesn't run elsewhere.
8. **Signal handling** — the helper ignores `SIGPIPE` and relies on QEMU overriding
   SIGTERM handlers (`os_setup_signal_handlers`). Linux: same. Windows: no POSIX
   signals — `DeviceHost.halt`'s SIGTERM/SIGINT path needs a Win32 equivalent
   (console control handler / explicit quit).
9. **`install_name @rpath/...`** — Mach-O only; Linux uses `SONAME` + rpath,
   Windows uses DLL search order. The "which build runs" selection logic
   (`Qemu.candidates()`) must be reimplemented per platform, keeping the
   `LTM_QEMU_DYLIB` debug override.
10. **No Cocoa/Mach types cross the ABI.** The C surface is pure C99
    (`<stdbool.h>`, `<stdint.h>`, `<stddef.h>` only) plus the one `QemuIosDeviceInfo`
    struct whose layout is identical on LP64 and LLP64. x86-64 has a single calling
    convention per OS, so `@convention(c)` behaves the same everywhere. The
    fragility is all *around* the ABI (keycodes, image UUID, loader, signals,
    thread lifetime), not in the call signatures.

---

## 7. What Phase 5/6 must replicate per platform

- [ ] Build qemu-ios for the target (meson/ninja; the dylib recipe in
      `make-dylib-macos.sh` is the template: take the real `qemu-system-arm` link
      line, swap `system/main.c` for `qemu-ios-entry.c`, add `qemu-ios-ui.o` and a
      platform extras object).
- [ ] Compile the three ABI shims: `contrib/ios-app/qemu-ios-entry.c`,
      `contrib/ios-app/qemu-ios-ui.c` (reused unchanged), and a platform extras
      file replacing `contrib/macos-app/qemu-macos-extras.c`'s Mach pieces
      (`mach-o/loader.h` in `qemu_ios_build_id`; `qemu_input_map_osx_to_qcode` in
      `qemu_ios_ui_key_mac`).
- [ ] Link `libqemu-arm.so` / `qemu-arm.dll` exporting **exactly the 55 symbols**
      in §2: Linux `--version-script` (names without the `_` prefix) or
      `--dynamic-list`; Windows `.def` `EXPORTS` (or `__declspec(dllexport)`).
      Keep `qemu_ios_api_version` at major 2; the Swift loader refuses anything else.
- [ ] Decide the keycode story (§6.1): new `qemu_ios_ui_key_*` entry points or
      Swift-side translation to QKeyCode — and update `LinkCommand.key` producers.
- [ ] Decide `qemu_ios_build_id` per platform (§6.2) — ELF build-id / PE GUID, or
      documented NULL.
- [ ] Fix the `unsigned long errlen` in `qemu_ios_snapshot_status` (§6.3).
- [ ] Reimplement dylib discovery per platform (`LTM_QEMU_DYLIB` override,
      bundle/app-relative path, rpath/`$ORIGIN`/DLL search) with `RTLD_NOW`-like
      eager symbol checking and the major-version gate.
- [ ] Preserve the threading contract: `qemu_ios_main` on one background thread,
      once per process; never exit the loading thread before it returns; all other
      entry points stay app-thread safe via bottom halves; `qemu_ios_ui_ready()`
      gates.
- [ ] Verify the frame path per platform: `-display none` console surface must be
      32-bit BGRA for `ios_capture`'s raw `memcpy`; confirm the 3-buffer borrow
      semantics hold under the platform's QEMU display code.
- [ ] Verify audio: 44100 Hz stereo S16LE mixer capture, 16384-byte reads,
      generation semantics.
- [ ] Ship the guest artifacts portably: build `guest-tools/` + `ipad-guest-tools/`
      + `manifest.json` once (macOS-only build step is fine — the outputs are
      data), but replace the Apple-Archive `guest.aar` + `AppleArchive` unpacker
      with something Linux/Windows can read, and unpack to the platform's cache dir.
- [ ] Keep the 8-machine `QemuIosDeviceInfo` table (or extend it) — `DeviceInfo`,
      board facts, and the `machines` helper mode all derive from
      `qemu_ios_device_info_at`.
- [ ] Keep the optional-symbol discipline: new entry points = minor bump only;
      a major bump means the Swift `Qemu.apiMajor` must move in lockstep.
