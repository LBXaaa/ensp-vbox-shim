# Architecture

How `ensp-vbox-shim` lets Huawei eNSP (built for VirtualBox **5.2**) drive a
real VirtualBox **7.2.8** install, unmodified, underneath it.

## The problem

eNSP ships against the VirtualBox 5.2 COM API. VBox 5.2 does not install
cleanly on current Windows builds, but 7.2.x does. The two APIs are *not*
binary-compatible:

- VBox 7.x `IVirtualBox` derives from `IDispatch` (7 base slots) where 5.2
  derives from `IUnknown` (3 base slots), so every method moved by +4.
- 7.x also **inserted new properties/methods and reordered existing ones** —
  the vtable is not a uniform `+4` shift past `get_guestOSTypes`. See
  [vtable-mapping.md](vtable-mapping.md).
- eNSP gates on the registry version string and refuses anything that is not
  `5.2.x`.

So eNSP cannot call 7.2 directly. The shim sits in between and presents a
5.2-shaped surface backed by the live 7.2 server.

## Boot chain

```
eNSP_Client.exe
  └─ eNSP_VBoxServer.exe              (32-bit host process)
       └─ LoadLibrary  tools\VBox52.dll          ← our shim
            └─ GetVBoxInstance()                  ← our export
                 └─ CoCreateInstance(CLSID_VirtualBox, CLSCTX_LOCAL_SERVER,
                                      IID_VBox7_IVirtualBox)
                      └─ VBoxSVC.exe              (real out-of-process 7.2.8 server)
```

eNSP is **32-bit**, so everything below it runs in WOW64 and reads the
`WOW6432Node` registry view.

## The three load-bearing bridges

All three are required. Remove any one and eNSP fails (version gate rejects,
COM object is wrong shape, or the AR router plugin crashes on start).

### 1. Version spoof (registry)

`HKLM\SOFTWARE\[WOW6432Node\]Oracle\VirtualBox` `Version`/`VersionExt` are set
to `5.2.44` / `5.2.44r139111`. The binaries are really `7.2.8.173730`; only the
strings lie. This gets eNSP past its pre-COM version gate. See
[`registry/01_version_spoof.reg`](../registry/01_version_spoof.reg).

There is a **second, in-process** version spoof inside the shim: the proxy's
`get_version` / `get_versionNormalized` / `get_revision` vtable slots return a
hardcoded `5.2.22` instead of forwarding to the real object (which would answer
`7.2.8`). See `src/spoof_thunks.cpp`. The registry spoof is read *before* COM;
the in-process spoof is read *after* eNSP holds the `IVirtualBox` pointer.

### 2. VBox52.dll — the COM/vtable shim

A 32-bit DLL deployed to `…\Huawei\eNSP\tools\VBox52.dll`. It exposes **four**
exports:

| export | linkage | who calls it |
|--------|---------|--------------|
| `GetVBoxInstance`   | `.def` + `__declspec(dllexport)` | eNSP_VBoxServer.exe, directly by name |
| `DelVBoxInstance`   | `.def` + `__declspec(dllexport)` | eNSP_VBoxServer.exe teardown |
| `DllGetClassObject` | `#pragma … /export`              | COM, via the InprocServer32 hijack |
| `DllCanUnloadNow`   | `#pragma … /export`              | COM (returns `S_FALSE`, never unload) |

**Two entry paths, one proxy object.** Both paths end at the same structure:

- **Export path:** `GetVBoxInstance()` → `CoCreateInstance(CLSCTX_LOCAL_SERVER,
  IID_VBox7_IVirtualBox)` → wraps the real object → returns the proxy view.
- **COM path:** the registry repoints `CLSID_VirtualBox`'s 32-bit
  `InprocServer32` at VBox52.dll (see
  [`registry/02_clsid_inprocserver.reg`](../registry/02_clsid_inprocserver.reg)).
  A 32-bit `CoCreateInstance(CLSID_VirtualBox)` then loads us, calls our
  `DllGetClassObject` → returns `g_factory` → `Factory_CreateInstance` calls
  `CoCreateInstance(CLSID_VirtualBox, CLSCTX_LOCAL_SERVER, …)` to reach the real
  out-of-process 7.2 `VBoxSVC.exe` (the explicit `CLSCTX_LOCAL_SERVER` bypasses
  our own InprocServer32 and avoids infinite recursion), then wraps it.

**Proxy object shape** (`src/vbox52_proxy.cpp`):

```c
struct VBoxProxyView { const void** vtable; void* self1; void* self2; IUnknown* realVBox; };
//                     +0                    +4          +8          +12
struct VBoxProxyRoot { LONG refCount; VBoxProxyView view; };  // refCount at view-4
```

`vtable` points at `g_vbox52_vtable`, a **50-slot 5.2 `IVirtualBox` layout**.
Each slot is a naked thunk (`src/vbox52_thunks.asm`) that reads `realVBox` from
`[ecx+12]` and tail-jumps into the **real 7.2 vtable at the remapped index**
(e.g. 5.2 `createDHCPServer` slot 30 → 7.2 index 57). The full per-slot map is
in [vtable-mapping.md](vtable-mapping.md).

**IMachine wrapping.** `findMachine` / `openMachine` / `registerMachine` return
or take `IMachine*`, which has the *same* 5.2→7.2 vtable drift. Those slots use
special thunks that wrap the real 7.2 `IMachine` in a `MachineProxy`
(`src/imachine_entries.asm`):

```
MachineProxy:  +0 vtable   +8 realMachine   +12 per-slot 7.2-index map
```

The `im_e_N` thunks read the real machine from `[this+8]` and the destination
7.2 index from `map[N]`, then tail-jump — same remap trick, but table-driven
instead of one hand-written thunk per slot.

**IAT hooks** (installed into the host process on first proxy creation,
`install_iat_hook`):

- `ole32!CoGetClassObject` → intercepts `CLSID_VirtualBox` and hands back
  `g_factory` (the proxy factory) so an in-process `CoGetClassObject` is bridged
  too. A `g_factory_guard` flag prevents recursion.
- `kernel32!CreateProcessW` → **observe-only.** Logs each child command line to
  `C:\vbox\vboxmanage_wrapper.log`, then calls the real `CreateProcessW`
  **unchanged**. It does not rewrite arguments or redirect the target. Purely
  diagnostic; safe to ignore or strip.

A process-wide **VEH** is also installed as an **observe-only** crash logger: it
records every exception and never alters control flow.

### 3. VAR_Plugin.dll byte patch (AR router only)

The `plugin\ar1000v\VAR_Plugin.dll` plugin does **not** go through the proxy for
everything — it holds a real 7.2 `IVirtualBox` pointer and calls it through
**hard-coded 5.2 vtable offsets**. On 7.x those offsets land on the wrong
methods (e.g. 5.2 `findMachine` would hit 7.2 `getPlatformProperties`) and AR
crashes on start.

The fix is a 29-byte, 28-site in-place patch that rewrites only the displacement
byte of each `call [reg+disp]`, remapping every 5.2 slot to its 7.2 slot. File
size is unchanged and the edit is fully reversible. Spec and patcher in
[`patches/`](../patches/). This bridge is **independent** of VBox52.dll — both
are needed for AR.

## Optional: VBoxManage.exe wrapper

A working install may also contain a `VBoxManage.exe` shim that logs each
invocation and forwards verbatim to `VBoxManage_real.exe` (the real 7.2.8 CLI).
It is **diagnostic, not load-bearing** — eNSP's `clonevm` / `modifyvm` /
`startvm` are native 7.2.8 commands and run fine against the real binary. Its
source is **not** in this repo, and nothing here depends on it.

## What is and isn't shipped

This repo ships **our** source, the patcher, and `.reg` files. It ships **no**
Huawei or Oracle binaries. `build/VBox52.dll` is our own compiled output from
`src/`. To restore a stock install, see [`registry/README.md`](../registry/README.md)
(version strings) and `patches/` (`--restore`).

See [manifest.md](manifest.md) for the per-file load-bearing breakdown.
