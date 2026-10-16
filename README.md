# lighttouch-emulator

Build docs, patches, ABI contract and validation for the qemu-ios emulator used by the LightTouchMac cross-platform port.

`qemu-ios/` and `qemu-ios-abi/` are pinned upstream clones (qemu-ios @ `cb3595e8add3d9a3a55807186c6b8ff0ba338abe`, the exact commit LightTouchMac pins in `build-support/sources.json`) — reproducible via `git clone`, intentionally not vendored here.
