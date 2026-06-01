# registry/

Windows registry edits that wire eNSP up to the shim. They reproduce, on a
fresh machine, the two registry-level changes the shim install makes. All
values were verified against a live working install.

Import order matters: **version spoof, then CLSID hijack**.

```bat
reg import 01_version_spoof.reg
reg import 02_clsid_inprocserver.reg
```

(Or double-click each .reg. Administrator rights required — these write HKLM.)

## What each file does

| file | effect |
|------|--------|
| `01_version_spoof.reg`      | sets `Oracle\VirtualBox` `Version`=5.2.44 / `VersionExt`=5.2.44r139111 in both 64-bit and 32-bit views, so eNSP's 5.2.x version gate passes (the machine really runs 7.2.8) |
| `02_clsid_inprocserver.reg` | repoints `CLSID_VirtualBox` `{B1A7A4F2-…}` InprocServer32 → `…\Huawei\eNSP\tools\VBox52.dll` in both views, so eNSP's 32-bit `CoCreateInstance` loads the shim instead of VBox's native proxy/stub |
| `99_uninstall.reg`          | restores the real version strings (7.2.8 r173730). Does **not** undo the CLSID hijack — see below |

## Paths

The .reg files use the standard install locations:

- eNSP: `C:\Program Files\Huawei\eNSP\tools\VBox52.dll`
- VirtualBox: `C:\Program Files\Oracle\VirtualBox\`

If your installs live elsewhere, edit the paths before importing.

## Prerequisites

- VirtualBox **7.2.x** installed (the binaries must really be 7.2; only the
  registry pretends to be 5.2).
- `VBox52.dll` built and copied to `…\eNSP\tools\` (see `build/`).

## Uninstalling

1. `reg import 99_uninstall.reg` — puts the version strings back to 7.2.8.
2. Restore VirtualBox's native COM registration. The shim overwrote the
   InprocServer32 for `CLSID_VirtualBox`, a key that Oracle's installer owns.
   The authoritative way to put the correct value back is to run **Repair** on
   VirtualBox 7.2.8 from "Apps & features" (or reinstall it). That rewrites the
   CLSID to VBox's own 32-bit proxy/stub
   (`…\Oracle\VirtualBox\x86\VBoxProxyStub-x86.dll`) for you.

   We deliberately do not ship a .reg that hardcodes that path: it varies by
   VBox build, and a wrong value would break COM. Letting Oracle's own
   installer rewrite it is the safe restore.

## Why two views

eNSP is a 32-bit process, so it reads the `WOW6432Node` (32-bit) registry view.
The 64-bit view is set to match for any 64-bit tooling that inspects VirtualBox.
