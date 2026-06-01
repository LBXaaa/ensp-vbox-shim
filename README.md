# ensp-vbox-shim

Run **Huawei eNSP** on **VirtualBox 7.2.x** instead of the ancient VirtualBox
5.2 it ships against — with the real 7.2 hypervisor underneath, unmodified.

eNSP is built against the VirtualBox **5.2** COM API. VBox 5.2 no longer
installs cleanly on current Windows; VBox 7.2 does, but its COM interface is not
binary-compatible (7.x `IVirtualBox` derives from `IDispatch`, inserts new
methods, and reorders existing ones). eNSP also hard-refuses any version that
isn't `5.2.x`.

This project bridges that gap with a small COM/vtable shim plus a reversible
byte patch, so eNSP talks 5.2 while a stock VirtualBox 7.2.8 does the work.
Verified end-to-end: an AR router boots to its `<Huawei>` CLI and an AC6605
to `<AC6605>`.

## How it works

Three load-bearing pieces (full detail in [docs/](docs/)):

1. **`VBox52.dll`** — a 32-bit shim deployed to `eNSP\tools\`. It exposes a
   **5.2-shaped `IVirtualBox` vtable** over the live 7.2 object, forwarding each
   slot to the correct (remapped) 7.2 method. Reached two ways: eNSP's
   `GetVBoxInstance()` export call, and a COM `InprocServer32` class factory.
2. **Version spoof** — registry `Version`/`VersionExt` read `5.2.44` so eNSP's
   gate passes (binaries are really `7.2.8.173730`); the shim also answers
   `5.2.22` from `get_version` in-process.
3. **`VAR_Plugin.dll` patch** — the AR router plugin calls `IVirtualBox` directly
   through hard-coded 5.2 vtable offsets; a 28-site, 29-byte reversible patch
   remaps them to 7.2.

```
eNSP_Client.exe → eNSP_VBoxServer.exe → VBox52.dll (shim) → VBoxSVC.exe 7.2.8
```

See [docs/architecture.md](docs/architecture.md) for the full picture,
[docs/vtable-mapping.md](docs/vtable-mapping.md) for the authoritative slot
table, and [docs/manifest.md](docs/manifest.md) for what is load-bearing vs.
diagnostic.

## Repository layout

| dir | contents |
|-----|----------|
| [`src/`](src/)         | shim source: `vbox52_proxy.cpp`, `vbox52_thunks.asm`, `spoof_thunks.cpp`, `imachine_entries.asm`, `vbox52.def` |
| [`build/`](build/)     | `build.bat` (32-bit MSVC) and our prebuilt `VBox52.dll` |
| [`patches/`](patches/) | `patch_var_plugin.py` + spec for the AR plugin patch |
| [`registry/`](registry/) | `.reg` files: version spoof, CLSID hijack, uninstall |
| [`docs/`](docs/)       | architecture, vtable mapping, load-bearing manifest |
| [`analysis/`](analysis/) | the reverse-engineering scripts and findings behind it all |

## Install

Requires **VirtualBox 7.2.x** and **Huawei eNSP** already installed, and (to
rebuild) a 32-bit MSVC toolchain. Administrator rights are needed for the
registry and `Program Files` edits.

```bat
:: 1. shim — build (or use build\VBox52.dll) and copy into eNSP
build\build.bat
copy build\VBox52.dll "C:\Program Files\Huawei\eNSP\tools\VBox52.dll"

:: 2. registry — version spoof, then CLSID hijack
reg import registry\01_version_spoof.reg
reg import registry\02_clsid_inprocserver.reg

:: 3. AR plugin patch (writes a .bak first)
python patches\patch_var_plugin.py "C:\Program Files\Huawei\eNSP\plugin\ar1000v\VAR_Plugin.dll"
```

Then start eNSP and launch a device. To undo, see
[registry/README.md](registry/README.md) and
`python patches\patch_var_plugin.py --restore …`.

## What this repo does and does not ship

It ships **our** source, the patcher, `.reg` files, and our own compiled
`VBox52.dll`. It ships **no** Huawei or Oracle binaries. The patcher edits
*your* installed copies in place and is fully reversible (verified by hash
round-trip).

## License

MIT for our code — see [LICENSE](LICENSE). VirtualBox and eNSP are the property
of their respective owners; this project interoperates with them but
redistributes neither.
