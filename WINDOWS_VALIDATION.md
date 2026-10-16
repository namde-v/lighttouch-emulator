# Windows qemu-ios Build Validation

**Date:** 2026-10-16 ~08:12 UTC (15:12 +07)
**Validator:** CI-artifact validation agent
**Verdict: NOT VALIDATED — no successful build artifact available**

## What was checked

The `windows-emulator-ci.yml` workflow on `namde-v/lighttouch-cross` was polled every
~10 minutes for 90 minutes (06:41–08:11 UTC) for a completed successful run.

## Run history observed

| Run ID | Status | Conclusion | Notes |
|---|---|---|---|
| 38862916239 | completed | cancelled | superseded by newer push |
| 38863068267 | completed | failure | build failed (log not inspected in depth — no green artifact to validate) |
| 38864334326 | completed | cancelled | superseded by newer push |
| 38865825075 | completed | cancelled | superseded by newer push |
| 38867494978 | completed | cancelled | superseded by newer push |
| 38867660561 | completed | failure | build failed |
| 38870639894 | in_progress | — | still running when the 90-min window elapsed |

Zero successful runs in the window. The build agent is iterating rapidly (frequent
pushes cancelling previous runs), so a green run may land soon after this report.

## Validation checks (not performed — no artifact)

1. ⏭ `file` → PE32+ x86-64 — no binary downloaded
2. ⏭ `strings` → QEMU version string — no binary downloaded
3. ⏭ Build log → ARM / iOS machine targets enabled, not silently skipped — no green log
4. ⏭ DLL dependency listing — no binary downloaded

## Recommendation

Re-dispatch validation once a `windows-emulator-ci.yml` run completes with
`conclusion == success` (e.g. watch run 38870639894, which was in progress at
08:12 UTC). Then: `gh run download <id> --repo namde-v/lighttouch-cross`,
verify PE32+ x86-64 via `file`, QEMU version via `strings`, confirm
`arm-softmmu` / iOS machine targets in the configure log, and list DLL imports.
