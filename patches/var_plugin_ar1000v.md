# VAR_Plugin.dll (ar1000v) — IVirtualBox vtable 5.2 → 7.2 remap

## What this patch is

`plugin\ar1000v\VAR_Plugin.dll` is Huawei eNSP's AR (router) device plugin.
Unlike the rest of eNSP — which reaches VirtualBox through `eNSP_VBoxServer.exe`
and our `VBox52.dll` proxy — this plugin holds a **real 7.2 `IVirtualBox`
pointer** and dispatches through it directly, with vtable offsets **hard-coded
for the VirtualBox 5.2 ABI**.

On VirtualBox 7.x the `IVirtualBox` vtable was reorganized (IDispatch base
inserted, new properties/methods added, **existing methods reordered**). A 5.2
offset therefore lands on the *wrong* 7.2 method. For example the plugin's
`findMachine` uses 5.2 slot 37, which on 7.2 is `getPlatformProperties` — so the
unpatched plugin calls the wrong method and crashes during AR start.

This patch rewrites **only the displacement byte(s)** of 28 `call [reg+disp]`
virtual-dispatch instructions so each one targets the correct 7.2 slot. No code
is inserted, moved, or resized — the file stays 393216 bytes.

## Two complementary bridges (both required for AR)

1. **VBox52.dll proxy** — handles the `eNSP_VBoxServer` path
   (`GetVBoxInstance` → vtable[1] clone-precheck).
2. **VAR_Plugin.dll byte-patch (this)** — handles the ar1000v plugin's *direct*
   `IVirtualBox` calls.

Removing either one breaks AR. This was confirmed by byte-level static
disassembly: all 28 sites are method→same-method remaps; none is incidental.

## Binary identity

| state    | size   | SHA256 |
|----------|--------|--------|
| pristine | 393216 | `5ae6817a9f2f05cfbb5f1f89af910007c22988c22bc02fdf2c44a67a9ff26eb5` |
| patched  | 393216 | `f0107975ba1b04325af2d31189ee92833233c1163f4553600207789977f94451` |

The pristine binary is the fixed 2019 factory build shipped with eNSP. The
patcher refuses any other input.

## Instruction shape

Each site is a `__thiscall` virtual dispatch. The `this` pointer is loaded into
`ecx` (`8B C8` mov ecx,eax / `8B CE` mov ecx,esi / `8B CB` mov ecx,ebx), then:

```
FF 90 <disp32>    call dword ptr [eax + disp]
FF 92 <disp32>    call dword ptr [edx + disp]
```

`disp / 4` = vtable slot index. The patch changes only the low byte(s) of
`disp`. All displacements fit in one byte except `checkFirmwarePresent`, whose
7.2 displacement `0x0118` crosses the 0xFF boundary, so its patch touches two
bytes (`D0 00` → `18 01`).

## The 28 sites (29 bytes)

`offset` is the file offset of the displacement's low byte. `5.2→7.2` is the
displacement value; `slot` is `disp/4`. See the project `CLAUDE.md` for the full
5.2 and 7.2 `IVirtualBox` vtable tables this maps against.

| file offset(s)                          | disp 5.2→7.2 | slot 5.2→7.2 | method |
|-----------------------------------------|--------------|--------------|--------|
| 0x01754C, 0x017F03, 0x021FFA            | 0x88 → 0xCC  | 34 → 51      | createSharedFolder |
| 0x01ED4B                                | 0x8C → 0xB4  | 35 → 45      | createUnattendedInstaller |
| 0x01ED99, 0x01FE99                      | 0x90 → 0xE8  | 36 → 58      | findDHCPServerByNetworkName |
| 0x01EDF3, 0x0216F8                      | 0x94 → 0xA4  | 37 → 41      | findMachine |
| 0x01EE4D                                | 0x98 → 0xF4  | 38 → 61      | findNATNetworkByName |
| 0x0168C8, 0x0168DD, 0x01BF35, 0x01EEA7  | 0x9C → 0xD8  | 39 → 54      | getExtraData |
| 0x01EF01                                | 0xA0 → 0xD4  | 40 → 53      | getExtraDataKeys |
| 0x01EF5B                                | 0xA4 → 0xC0  | 41 → 48      | getGuestOSType |
| 0x01EFB5                                | 0xA8 → 0xAC  | 42 → 43      | getMachineStates |
| 0x01F00F                                | 0xAC → 0xA8  | 43 → 42      | getMachinesByGroups |
| 0x0177DC, 0x01F06C                      | 0xB0 → 0x9C  | 44 → 39      | openMachine |
| 0x0172BA, 0x01F0C6                      | 0xB4 → 0xBC  | 45 → 47      | openMedium |
| 0x01F114                                | 0xB8 → 0xA0  | 46 → 40      | registerMachine |
| 0x01F162                                | 0xBC → 0xEC  | 47 → 59      | removeDHCPServer |
| 0x01F1BC                                | 0xC0 → 0xF8  | 48 → 62      | removeNATNetwork |
| 0x01F216                                | 0xC4 → 0xD0  | 49 → 52      | removeSharedFolder |
| 0x01F279                                | 0xC8 → 0xDC  | 50 → 55      | setExtraData |
| 0x01F2D6                                | 0xCC → 0xE0  | 51 → 56      | setSettingsSecret |
| 0x01F32A (+0x01F32B)                    | 0x0D0 → 0x118| 52 → 70      | checkFirmwarePresent ← 2-byte |

28 call sites, 29 displacement bytes. Verified by exhaustive byte-diff of the
pristine vs. patched factory binary (`patch_var_plugin.py` reproduces the patched
SHA256 exactly, and `--restore` reproduces the pristine SHA256 exactly).

## Applying

```
python patch_var_plugin.py "C:\Program Files\Huawei\eNSP\plugin\ar1000v\VAR_Plugin.dll"
```

A `.bak` of the pristine file is written next to the DLL unless `--no-backup`
is given. `--check` reports state without writing; `--restore` reverts.
