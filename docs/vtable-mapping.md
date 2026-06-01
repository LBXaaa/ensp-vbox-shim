# IVirtualBox vtable mapping (5.2 → 7.2)

The proxy in `src/` presents a **5.2-shaped `IVirtualBox` vtable** and forwards
each slot to the **real 7.2.8 object** at its remapped index. This file is the
authoritative slot table; it is transcribed directly from
`src/vbox52_proxy.cpp` (`g_vbox52_vtable[]`) and `src/vbox52_thunks.asm`.

## Why the layouts differ

VBox 7.x is **not** a uniform shift of 5.2:

1. **Different base interface.** 5.2 `IVirtualBox : IUnknown` (3 base slots:
   QueryInterface, AddRef, Release). 7.2 `IVirtualBox : IDispatch` (7 base slots:
   + GetTypeInfoCount, GetTypeInfo, GetIDsOfNames, Invoke). Everything past the
   base shifts by +4.
2. **New properties inserted mid-table** — `guestOSFamilies`, `hostOnlyNetworks`,
   `cloudNetworks`, `cloudProviderManager`.
3. **New methods inserted AND existing methods reordered** — e.g. 5.2
   `createDHCPServer` is the 3rd method but in 7.2 it is the 22nd. 17 new methods
   total.

So past `get_guestOSTypes` the offset is no longer a constant `+4`. Every slot is
mapped individually below.

## The proxy vtable (what eNSP sees)

53 slots, `[0]`–`[52]`. Three kinds of slot:

- **spoof** — handled locally, returns a hardcoded 5.2 string, does **not** touch
  the real object (`src/spoof_thunks.cpp`).
- **forward → 7.2[N]** — naked thunk reads `realVBox` from `[ecx+12]` and
  tail-jumps the real 7.2 vtable at index `N` (`src/vbox52_thunks.asm`,
  `UNI_THUNK_DIAG`).
- **wrap** — forwards, then wraps the returned/!passed `IMachine*` in a
  `MachineProxy` so the caller gets a 5.2-shaped machine too
  (`src/imachine_entries.asm`).

| 5.2 slot | method | kind | → 7.2 |
|---:|---|---|---:|
| 0  | QueryInterface | IUnknown (forward) | 0 |
| 1  | **clone precondition probe** | special (`ret 0xc`, **not** AddRef) | — |
| 2  | Release | IUnknown (forward) | 2 |
| 3  | get_version | spoof `"5.2.22"` | — |
| 4  | get_versionNormalized | spoof `"5.2.22"` | — |
| 5  | get_revision | spoof `"22"` | — |
| 6  | get_packageType | spoof `"5.2.22"` | — |
| 7  | get_APIVersion | forward | 11 |
| 8  | get_APIRevision | forward | 12 |
| 9  | get_homeFolder | forward | 13 |
| 10 | get_settingsFilePath | forward | 14 |
| 11 | get_host | forward | 15 |
| 12 | get_systemProperties | forward | 16 |
| 13 | get_machines | forward | 17 |
| 14 | get_machineGroups | forward | 18 |
| 15 | get_hardDisks | forward | 19 |
| 16 | get_DVDImages | forward | 20 |
| 17 | get_floppyImages | forward | 21 |
| 18 | get_progressOperations | forward | 22 |
| 19 | get_guestOSTypes | forward | 23 |
| 20 | get_sharedFolders | forward | 25 |
| 21 | get_performanceCollector | forward | 26 |
| 22 | get_DHCPServers | forward | 27 |
| 23 | get_NATNetworks | forward | 28 |
| 24 | get_eventSource | forward | 29 |
| 25 | get_extensionPackManager | forward | 30 |
| 26 | get_internalNetworks | forward | 31 |
| 27 | get_genericNetworkDrivers | forward | 33 |
| 28 | composeMachineFilename | forward | 36 |
| 29 | createAppliance | forward | 44 |
| 30 | createDHCPServer | forward | 57 |
| 31 | createMachine | forward | 38 |
| 32 | createMedium | forward | 46 |
| 33 | createNATNetwork | forward | 60 |
| 34 | createSharedFolder | forward | 51 |
| 35 | createUnattendedInstaller | forward | 45 |
| 36 | findDHCPServerByNetworkName | forward | 58 |
| 37 | findMachine | **wrap** (IMachine result) | 41 |
| 38 | findNATNetworkByName | forward | 61 |
| 39 | getExtraData | forward | 54 |
| 40 | getExtraDataKeys | forward | 53 |
| 41 | getGuestOSType | forward | 48 |
| 42 | getMachineStates | forward | 43 |
| 43 | getMachinesByGroups | forward | 42 |
| 44 | openMachine | **wrap** (IMachine result) | 39 |
| 45 | openMedium | forward | 47 |
| 46 | registerMachine | **wrap** (IMachine arg) | 40 |
| 47 | removeDHCPServer | forward | 59 |
| 48 | removeNATNetwork | forward | 62 |
| 49 | removeSharedFolder | forward | 52 |
| 50 | setExtraData | forward | 55 |
| 51 | setSettingsSecret | forward | 56 |
| 52 | checkFirmwarePresent | forward | 70 |

### Notes on the special slots

- **Slot [1] is a clone precondition probe, not AddRef.** In practice eNSP's
  *only* call through this object is slot [1]: a `__thiscall` with three stack
  args and `ret 0xc`, of the shape
  `HRESULT m(this, BSTR base, BSTR snapshot, HRESULT* pOut)`. The thunk forwards
  to `helper_clone_check(realVBox, base, snap, pOut)`. Putting AddRef here (a
  `ret 4` shape) drifted eNSP's stack by 8 bytes and crashed it — the slot
  contract was recovered empirically. `AddRef` therefore has **no** live slot in
  the proxy vtable (a minimal `thunk_AR` exists in the asm but is unused).
- **Slots [3]–[6] are spoofed locally.** Forwarding `get_version` to the real
  object would answer `7.2.8`; eNSP must read `5.2.x`. This is the in-process
  half of the version spoof (the registry half is in `registry/`).
- **Slots [37]/[44]/[46] wrap `IMachine`.** `IMachine` has the same 5.2→7.2
  drift; see below.

## IMachine wrapping

`findMachine`/`openMachine` return an `IMachine*`, and `registerMachine` takes
one. The returned 7.2 machine is wrapped in a `MachineProxy`
(`src/imachine_entries.asm`):

```
MachineProxy:  +0 vtable(5.2-shaped)   +8 real 7.2 IMachine   +12 per-slot 7.2-index map
```

Unlike `IVirtualBox` (one hand-written thunk per slot), the `IMachine` thunks
(`im_e_N`) are **table-driven**: each reads the real machine from `[this+8]` and
its destination 7.2 index from `map[N]` (`[this+12]`), then tail-jumps. The map
table encodes the same kind of 5.2→7.2 remap shown above, for `IMachine`.

## Reference: full 7.2.8 IVirtualBox layout

The destination side, for cross-checking the `→ 7.2` column. `IDispatch` base
`[0]`–`[6]`; properties `[7]`–`[35]`; methods `[36]`–`[73]`. **bold** = new in
7.x (no 5.2 equivalent).

| 7.2 | method | 7.2 | method |
|---:|---|---:|---|
| 7  | get_version              | 41 | findMachine |
| 8  | get_versionNormalized    | 42 | getMachinesByGroups |
| 9  | get_revision             | 43 | getMachineStates |
| 10 | get_packageType          | 44 | createAppliance |
| 11 | get_APIVersion           | 45 | createUnattendedInstaller |
| 12 | get_APIRevision          | 46 | createMedium |
| 13 | get_homeFolder           | 47 | openMedium |
| 14 | get_settingsFilePath     | 48 | getGuestOSType |
| 15 | get_host                 | 49 | **getGuestOSSubtypesByFamilyId** |
| 16 | get_systemProperties     | 50 | **getGuestOSDescsBySubtype** |
| 17 | get_machines             | 51 | createSharedFolder |
| 18 | get_machineGroups        | 52 | removeSharedFolder |
| 19 | get_hardDisks            | 53 | getExtraDataKeys |
| 20 | get_DVDImages            | 54 | getExtraData |
| 21 | get_floppyImages         | 55 | setExtraData |
| 22 | get_progressOperations   | 56 | setSettingsSecret |
| 23 | get_guestOSTypes         | 57 | createDHCPServer |
| 24 | **get_guestOSFamilies**  | 58 | findDHCPServerByNetworkName |
| 25 | get_sharedFolders        | 59 | removeDHCPServer |
| 26 | get_performanceCollector | 60 | createNATNetwork |
| 27 | get_DHCPServers          | 61 | findNATNetworkByName |
| 28 | get_NATNetworks          | 62 | removeNATNetwork |
| 29 | get_eventSource          | 63 | **createHostOnlyNetwork** |
| 30 | get_extensionPackManager | 64 | **findHostOnlyNetworkByName** |
| 31 | get_internalNetworks     | 65 | **findHostOnlyNetworkById** |
| 32 | **get_hostOnlyNetworks** | 66 | **removeHostOnlyNetwork** |
| 33 | get_genericNetworkDrivers| 67 | **createCloudNetwork** |
| 34 | **get_cloudNetworks**    | 68 | **findCloudNetworkByName** |
| 35 | **get_cloudProviderManager** | 69 | **removeCloudNetwork** |
| 36 | composeMachineFilename   | 70 | checkFirmwarePresent |
| 37 | **getPlatformProperties**| 71 | **findProgressById** |
| 38 | createMachine            | 72 | **getTrackedObject** |
| 39 | openMachine              | 73 | **getTrackedObjectIds** |
| 40 | registerMachine          |    | |

## Relationship to the VAR_Plugin patch

The AR plugin calls a real 7.2 `IVirtualBox` directly through hard-coded **5.2**
offsets, so it needs the *same* remap baked in as a byte patch. The
`patches/var_plugin_ar1000v.md` displacement table is exactly the `→ 7.2` column
above, expressed as `slot × 4` (e.g. `findMachine` 37→41 ⇒ disp `0x94`→`0xA4`).
The plugin only references a subset of methods (`createSharedFolder` [34]
through `checkFirmwarePresent` [52]), so only those slots appear in the patch.
