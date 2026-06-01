# Manifest — what is load-bearing

Every change this project makes to a stock eNSP + VirtualBox install, and
whether it is **required** for eNSP to run on 7.2, or merely **diagnostic**.

Legend:
- **REPLACED** — a file is swapped for ours.
- **PATCHED** — an existing file is edited in place (reversible).
- **REGISTRY** — a registry value is changed.
- **load-bearing** — remove it and eNSP fails.
- **diagnostic** — logging/observation only; safe to omit or strip.

## Load-bearing

| # | change | kind | location | why it's required |
|---|--------|------|----------|-------------------|
| 1 | `VBox52.dll` | REPLACED | `…\Huawei\eNSP\tools\VBox52.dll` | The COM/vtable shim. eNSP_VBoxServer.exe loads it and calls `GetVBoxInstance()`; it presents a 5.2 `IVirtualBox` over the real 7.2 object. Also serves the COM InprocServer32 class factory. |
| 2 | `VAR_Plugin.dll` (ar1000v) | PATCHED | `…\Huawei\eNSP\plugin\ar1000v\VAR_Plugin.dll` | The AR router plugin calls a real 7.2 `IVirtualBox` through hard-coded 5.2 vtable offsets. Without the 28-site remap patch, AR hits the wrong methods and crashes on start. Independent of #1 — both needed for AR. |
| 3 | Version spoof | REGISTRY | `HKLM\…\Oracle\VirtualBox` `Version`/`VersionExt` (both views) | eNSP's pre-COM version gate refuses anything not `5.2.x`. Strings read `5.2.44`; binaries are really `7.2.8.173730`. |
| 4 | CLSID InprocServer32 | REGISTRY | `CLSID\{B1A7A4F2-…}\InprocServer32` (both views) | Repoints the 32-bit in-proc server for `CLSID_VirtualBox` at `VBox52.dll`, so eNSP's `CoCreateInstance` loads our class factory instead of VBox's native proxy/stub. |

All four are verified against a live working install (AR reaches `<Huawei>`,
AC6605 reaches `<AC6605>`).

### In-process version spoof (part of #1)

Inside `VBox52.dll`, vtable slots `[3]`–`[6]` (`get_version`,
`get_versionNormalized`, `get_revision`, `get_packageType`) return a hardcoded
`5.2.22` instead of forwarding. This is **load-bearing**: it is the second half
of the version spoof, read *after* eNSP holds the object (the registry half is
read *before* COM). See `src/spoof_thunks.cpp`.

## Diagnostic (not load-bearing)

| change | location | what it does |
|--------|----------|--------------|
| `CreateProcessW` IAT hook | inside `VBox52.dll` | Observe-only. Logs each child command line to `C:\vbox\vboxmanage_wrapper.log`, then calls the real `CreateProcessW` **unchanged**. Does not rewrite arguments or redirect the target. |
| VEH crash logger | inside `VBox52.dll` | Observe-only vectored exception handler. Records exceptions; never alters control flow. |
| `VBoxManage.exe` wrapper | `…\Oracle\VirtualBox\` (a working install may have one) | Optional pass-through that logs invocations and forwards verbatim to `VBoxManage_real.exe`. eNSP's `clonevm`/`modifyvm`/`startvm` are native 7.2.8 commands and run fine against the real binary. **Source is not in this repo and nothing here depends on it.** |

These can be removed without affecting whether eNSP runs. They exist to make the
boot chain observable during bring-up.

## Prerequisites (user-supplied, not shipped)

| requirement | note |
|-------------|------|
| VirtualBox **7.2.x** installed | The real binaries must be 7.2; only the registry pretends to be 5.2. |
| Huawei eNSP installed | We patch *your* copy in place; this repo ships no Huawei binaries. |
| 32-bit MSVC toolchain | To rebuild `VBox52.dll` from `src/` (see `build/build.bat`). A prebuilt `build/VBox52.dll` is our own compiled output. |

## Restore / uninstall

| change | how to undo |
|--------|-------------|
| #1 `VBox52.dll` | Restore VirtualBox's native COM registration by running **Repair** (or reinstall) of VBox 7.2 — see `registry/README.md`. Remove our DLL from `eNSP\tools\`. |
| #2 `VAR_Plugin.dll` | `python patches\patch_var_plugin.py --restore <path>` (or restore the `.bak` the patcher wrote). Round-trip verified to reproduce the pristine hash exactly. |
| #3 Version spoof | `reg import registry\99_uninstall.reg` — restores `7.2.8` / `7.2.8r173730`. |
| #4 CLSID InprocServer32 | Deliberately **not** shipped as a `.reg` (the correct value is Oracle-build-specific). VBox **Repair**/reinstall rewrites it to the native proxy/stub. See `registry/README.md`. |

## Legal posture

This repo ships **our** source (`src/`), the patcher (`patches/`), `.reg` files
(`registry/`), and our own compiled `build/VBox52.dll`. It ships **no** Huawei or
Oracle binaries. The patcher edits *your* installed copies in place and is fully
reversible.
