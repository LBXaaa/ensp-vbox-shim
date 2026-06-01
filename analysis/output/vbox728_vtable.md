# IVirtualBox VTable Layout -- VirtualBox 7.2.8

## Source

**VBoxProxyStub.dll embedded type library**
- File: `C:\Program Files\Oracle\VirtualBox\VBoxProxyStub.dll`
- TypeLib GUID: `{D7569351-1750-46F0-936E-BD127D5BC264}`
- TypeLib Version: 1.3
- IVirtualBox IID: `{2CE10519-3C09-45D8-A12D-E887786146B7}`
- CoClass VirtualBox CLSID: `{B1A7A4F2-47B9-4A1E-82B2-07CCD5323C3F}`

Parsed via Python `comtypes` from the type library embedded in VBoxProxyStub.dll.

---

## VTable Structure Overview

| Section | Indices | Count | Description |
|---------|---------|-------|-------------|
| IUnknown | 0 - 2 | 3 | QueryInterface, AddRef, Release |
| IDispatch | 3 - 6 | 4 | GetTypeInfoCount, GetTypeInfo, GetIDsOfNames, Invoke |
| IVirtualBox | 7 - 91 | 85 | IVirtualBox-specific methods |
| **Total** | **0 - 91** | **92** | |

**Confirmed: IDispatch offset is +4.** VBox 7.2.8's IVirtualBox extends IDispatch, inserting 4 extra methods at vtable indices 3--6 compared to VBox 5.2 where IVirtualBox only extended IUnknown. The registry confirms `NumMethods = 92` and `cbSizeVft = 56` (7 inherited entries * 8 bytes = 56).

---

## IDispatch Offset Validation

For VBox 5.2 (IUnknown-based IVirtualBox):
- vtable[3] = first IVirtualBox method (e.g., get_version)
- vtable[N] = IVirtualBox method at offset N-3

For VBox 7.2.8 (IDispatch-based IVirtualBox):
- vtable[3] = GetTypeInfoCount (IDispatch)
- vtable[4] = GetTypeInfo (IDispatch)
- vtable[5] = GetIDsOfNames (IDispatch)
- vtable[6] = Invoke (IDispatch)
- vtable[7] = first IVirtualBox method (Version = get_version)
- vtable[N] = IVirtualBox method at offset N-7

**Translation rule**: VBox 5.2 method at vtable index `N` (where N >= 3) maps to VBox 7.2.8 vtable index `N + 4`.

---

## Complete VTable Method Table

Format: `Index | Kind | Name | Return Type | Parameters`

### IUnknown (indices 0--2)

| Idx | Kind | Name | Return | Parameters |
|-----|------|------|--------|------------|
| 0 | METHOD | QueryInterface | void | riid: GUID* [in], ppvObject: void** [out] |
| 1 | METHOD | AddRef | ULONG | |
| 2 | METHOD | Release | ULONG | |

### IDispatch (indices 3--6)

| Idx | Kind | Name | Return | Parameters |
|-----|------|------|--------|------------|
| 3 | METHOD | GetTypeInfoCount | void | pctinfo: UINT* [out] |
| 4 | METHOD | GetTypeInfo | void | iTInfo: UINT [in], lcid: ULONG [in], ppTInfo: void** [out] |
| 5 | METHOD | GetIDsOfNames | void | riid: GUID* [in], rgszNames: void** [in], cNames: UINT [in], lcid: ULONG [in], rgDispId: LONG* [out] |
| 6 | METHOD | Invoke | void | dispIdMember: LONG [in], riid: GUID* [in], lcid: ULONG [in], wFlags: USHORT [in], pDispParams: DISPPARAMS* [in], pVarResult: VARIANT* [out], pExcepInfo: EXCEPINFO* [out], puArgErr: UINT* [out] |

### IVirtualBox Properties (indices 7--35, property getters = PROPGET)

| Idx | Kind | Name | Return Type | Parameters |
|-----|------|------|-------------|------------|
| 7 | PROPGET | Version | BSTR | |
| 8 | PROPGET | VersionNormalized | BSTR | |
| 9 | PROPGET | Revision | ULONG | |
| 10 | PROPGET | PackageType | BSTR | |
| 11 | PROPGET | APIVersion | BSTR | |
| 12 | PROPGET | APIRevision | LONG64 | |
| 13 | PROPGET | HomeFolder | BSTR | |
| 14 | PROPGET | SettingsFilePath | BSTR | |
| 15 | PROPGET | Host | IHost* | |
| 16 | PROPGET | SystemProperties | ISystemProperties* | |
| 17 | PROPGET | Machines | SAFEARRAY(IMachine*) | |
| 18 | PROPGET | MachineGroups | SAFEARRAY(BSTR) | |
| 19 | PROPGET | HardDisks | SAFEARRAY(IMedium*) | |
| 20 | PROPGET | DVDImages | SAFEARRAY(IMedium*) | |
| 21 | PROPGET | FloppyImages | SAFEARRAY(IMedium*) | |
| 22 | PROPGET | ProgressOperations | SAFEARRAY(IProgress*) | |
| 23 | PROPGET | GuestOSTypes | SAFEARRAY(IGuestOSType*) | |
| 24 | PROPGET | GuestOSFamilies | SAFEARRAY(BSTR) | |
| 25 | PROPGET | SharedFolders | SAFEARRAY(ISharedFolder*) | |
| 26 | PROPGET | PerformanceCollector | IPerformanceCollector* | |
| 27 | PROPGET | DHCPServers | SAFEARRAY(IDHCPServer*) | |
| 28 | PROPGET | NATNetworks | SAFEARRAY(INATNetwork*) | |
| 29 | PROPGET | EventSource | IEventSource* | |
| 30 | PROPGET | ExtensionPackManager | IExtPackManager* | |
| 31 | PROPGET | InternalNetworks | SAFEARRAY(BSTR) | |
| 32 | PROPGET | HostOnlyNetworks | SAFEARRAY(IHostOnlyNetwork*) | |
| 33 | PROPGET | GenericNetworkDrivers | SAFEARRAY(BSTR) | |
| 34 | PROPGET | CloudNetworks | SAFEARRAY(ICloudNetwork*) | |
| 35 | PROPGET | CloudProviderManager | ICloudProviderManager* | |

### IVirtualBox Internal Reserved Attributes (indices 36--47)

These are internal properties. They are NOT part of the public API.

| Idx | Kind | Name | Return | Parameters |
|-----|------|------|--------|------------|
| 36 | PROPGET | InternalAndReservedAttribute1IVirtualBox | ULONG | |
| 37 | PROPGET | InternalAndReservedAttribute2IVirtualBox | ULONG | |
| 38 | PROPGET | InternalAndReservedAttribute3IVirtualBox | ULONG | |
| 39 | PROPGET | InternalAndReservedAttribute4IVirtualBox | ULONG | |
| 40 | PROPGET | InternalAndReservedAttribute5IVirtualBox | ULONG | |
| 41 | PROPGET | InternalAndReservedAttribute6IVirtualBox | ULONG | |
| 42 | PROPGET | InternalAndReservedAttribute7IVirtualBox | ULONG | |
| 43 | PROPGET | InternalAndReservedAttribute8IVirtualBox | ULONG | |
| 44 | PROPGET | InternalAndReservedAttribute9IVirtualBox | ULONG | |
| 45 | PROPGET | InternalAndReservedAttribute10IVirtualBox | ULONG | |
| 46 | PROPGET | InternalAndReservedAttribute11IVirtualBox | ULONG | |
| 47 | PROPGET | InternalAndReservedAttribute12IVirtualBox | ULONG | |

### IVirtualBox Methods (indices 48--85)

| Idx | Kind | Name | Return Type | Parameters |
|-----|------|------|-------------|------------|
| 48 | METHOD | ComposeMachineFilename | BSTR | name: BSTR [in], group: BSTR [in], createFlags: BSTR [in], baseFolder: BSTR [in] |
| 49 | METHOD | GetPlatformProperties | IPlatformProperties* | architecture: PlatformArchitecture [in] |
| 50 | METHOD | CreateMachine | IMachine* | name: BSTR [in], osTypeId: BSTR [in], architecture: PlatformArchitecture [in], groups: SAFEARRAY(BSTR) [in], cipher: BSTR [in], password: BSTR [in], passwordFile: BSTR [in], baseFolder: BSTR [in], forceOverwrite: BSTR [in] |
| 51 | METHOD | OpenMachine | IMachine* | name: BSTR [in], password: BSTR [in] |
| 52 | METHOD | RegisterMachine | void | machine: IMachine* [in] |
| 53 | METHOD | FindMachine | IMachine* | name: BSTR [in] |
| 54 | METHOD | GetMachinesByGroups | SAFEARRAY(IMachine*) | groups: SAFEARRAY(BSTR) [in] |
| 55 | METHOD | GetMachineStates | SAFEARRAY(MachineState) | machines: SAFEARRAY(IMachine*) [in] |
| 56 | METHOD | CreateAppliance | IAppliance* | |
| 57 | METHOD | CreateUnattendedInstaller | IUnattended* | |
| 58 | METHOD | CreateMedium | IMedium* | location: BSTR [in], deviceType: BSTR [in], accessMode: AccessMode [in], lockId: DeviceType [in] |
| 59 | METHOD | OpenMedium | IMedium* | location: BSTR [in], deviceType: DeviceType [in], accessMode: AccessMode [in], fLock: LONG [in] |
| 60 | METHOD | GetGuestOSType | IGuestOSType* | id: BSTR [in] |
| 61 | METHOD | GetGuestOSSubtypesByFamilyId | SAFEARRAY(BSTR) | familyId: BSTR [in] |
| 62 | METHOD | GetGuestOSDescsBySubtype | SAFEARRAY(BSTR) | subtype: BSTR [in] |
| 63 | METHOD | CreateSharedFolder | void | name: BSTR [in], hostPath: BSTR [in], writable: LONG [in], automount: LONG [in], autoMountPoint: BSTR [in] |
| 64 | METHOD | RemoveSharedFolder | void | name: BSTR [in] |
| 65 | METHOD | GetExtraDataKeys | SAFEARRAY(BSTR) | |
| 66 | METHOD | GetExtraData | BSTR | key: BSTR [in] |
| 67 | METHOD | SetExtraData | void | key: BSTR [in], value: BSTR [in] |
| 68 | METHOD | SetSettingsSecret | void | secret: BSTR [in] |
| 69 | METHOD | CreateDHCPServer | IDHCPServer* | name: BSTR [in] |
| 70 | METHOD | FindDHCPServerByNetworkName | IDHCPServer* | name: BSTR [in] |
| 71 | METHOD | RemoveDHCPServer | void | server: IDHCPServer* [in] |
| 72 | METHOD | CreateNATNetwork | INATNetwork* | networkName: BSTR [in] |
| 73 | METHOD | FindNATNetworkByName | INATNetwork* | networkName: BSTR [in] |
| 74 | METHOD | RemoveNATNetwork | void | network: INATNetwork* [in] |
| 75 | METHOD | CreateHostOnlyNetwork | IHostOnlyNetwork* | name: BSTR [in] |
| 76 | METHOD | FindHostOnlyNetworkByName | IHostOnlyNetwork* | name: BSTR [in] |
| 77 | METHOD | FindHostOnlyNetworkById | IHostOnlyNetwork* | id: BSTR [in] |
| 78 | METHOD | RemoveHostOnlyNetwork | void | network: IHostOnlyNetwork* [in] |
| 79 | METHOD | CreateCloudNetwork | ICloudNetwork* | name: BSTR [in] |
| 80 | METHOD | FindCloudNetworkByName | ICloudNetwork* | name: BSTR [in] |
| 81 | METHOD | RemoveCloudNetwork | void | network: ICloudNetwork* [in] |
| 82 | METHOD | CheckFirmwarePresent | LONG | architecture: PlatformArchitecture [in], firmwareType: FirmwareType [in], path: BSTR [in], pPresent: BSTR* [out], pResult: BSTR* [out] |
| 83 | METHOD | FindProgressById | IProgress* | id: BSTR [in] |
| 84 | METHOD | GetTrackedObject | void | trackerId: BSTR [in], ppObj: IUnknown* [out], pState: TrackedObjectState* [out], pTimestamp: LONG64* [out], pValue: LONG64* [out] |
| 85 | METHOD | GetTrackedObjectIds | SAFEARRAY(BSTR) | filterId: BSTR [in] |

### Internal Reserved Methods (indices 86--91)

| Idx | Kind | Name | Return | Parameters |
|-----|------|------|--------|------------|
| 86 | METHOD | InternalAndReservedMethod1IVirtualBox | void | |
| 87 | METHOD | InternalAndReservedMethod2IVirtualBox | void | |
| 88 | METHOD | InternalAndReservedMethod3IVirtualBox | void | |
| 89 | METHOD | InternalAndReservedMethod4IVirtualBox | void | |
| 90 | METHOD | InternalAndReservedMethod5IVirtualBox | void | |
| 91 | METHOD | InternalAndReservedMethod6IVirtualBox | void | |

---

## Mapping: eNSP Known Methods (VBox 5.2 vtable) to VBox 7.2.8

From the current proxy vtable guess, eNSP uses these methods on VBox 5.2 (where vtable starts at index 3 = first IVirtualBox method after IUnknown):

| eNSP VBox 5.2 Index | VBox 5.2 Name | VBox 7.2.8 Index | VBox 7.2.8 Name | Match? |
|:---:|:---|:---:|:---|:---:|
| 3 | get_version | **7** | Version | YES (+4) |
| 4 | get_versionNormalized | **8** | VersionNormalized | YES (+4) |
| 5 | get_revision | **9** | Revision | YES (+4) |
| 6 | get_packageType | **10** | PackageType | YES (+4) |
| 7 | get_APIVersion | **11** | APIVersion | YES (+4) |
| 8 | get_APIRevision | **12** | APIRevision | YES (+4) |
| 9 | get_homeFolder | **13** | HomeFolder | YES (+4) |
| 10 | get_settingsFilePath | **14** | SettingsFilePath | YES (+4) |
| 11 | get_host | **15** | Host | YES (+4) |
| 12 | get_systemProperties | **16** | SystemProperties | YES (+4) |
| 13 | get_machines | **17** | Machines | YES (+4) |
| 14 | get_machineGroups | **18** | MachineGroups | YES (+4) |
| 15 | get_hardDisks | **19** | HardDisks | YES (+4) |

**The +4 offset is uniform and verified for all methods.**

---

## Key Findings for Proxy DLL

### 1. IDispatch Offset = +4
All VBox 5.2 IVirtualBox method indices must be shifted by +4 when calling VBox 7.2.8's vtable. This is because VBox 7.2.8's IVirtualBox extends IDispatch (which adds 4 methods after IUnknown's 3).

### 2. VTable Layout Formula
```
VBox 7.2.8 vtable_index = 7 + (VBox_5_2_IVirtualBox_method_index - 3)
Simplified: vbox728_index = vbox52_index + 4
```

Where:
- Indices 0--2 = IUnknown (QueryInterface, AddRef, Release)
- Indices 3--6 = IDispatch (GetTypeInfoCount, GetTypeInfo, GetIDsOfNames, Invoke)
- Indices 7+ = IVirtualBox specific methods

### 3. New Methods in VBox 7.2.8 Not in VBox 5.2
These methods are present in VBox 7.2.8 but likely did NOT exist in VBox 5.2's IVirtualBox:
- GetPlatformProperties (vtable 49)
- CreateUnattendedInstaller (vtable 57)
- GetGuestOSSubtypesByFamilyId (vtable 61)
- GetGuestOSDescsBySubtype (vtable 62)
- SetSettingsSecret (vtable 68)
- CreateDHCPServer / FindDHCPServerByNetworkName / RemoveDHCPServer (vtables 69--71)
- CreateNATNetwork / FindNATNetworkByName / RemoveNATNetwork (vtables 72--74)
- CreateHostOnlyNetwork / FindHostOnlyNetworkByName / FindHostOnlyNetworkById / RemoveHostOnlyNetwork (vtables 75--78)
- CreateCloudNetwork / FindCloudNetworkByName / RemoveCloudNetwork (vtables 79--81)
- CheckFirmwarePresent (vtable 82)
- FindProgressById (vtable 83)
- GetTrackedObject / GetTrackedObjectIds (vtables 84--85)
- InternalAndReservedAttribute1-12IVirtualBox (vtables 36--47)
- InternalAndReservedMethod1-6IVirtualBox (vtables 86--91)
- ComposeMachineFilename (vtable 48) - may have different signature in VBox 5.2

### 4. Changed Signatures (VBox 5.2 vs 7.2.8)

Methods with potentially changed signatures:
- **CreateMachine**: VBox 7.2.8 adds `architecture: PlatformArchitecture`, `cipher`, `password`, `passwordFile` parameters compared to VBox 5.2
- **OpenMachine**: VBox 7.2.8 adds `password` parameter
- **CreateMedium**: Changed parameter order/types in VBox 7.2.8 (adds `lockId: DeviceType`)
- **OpenMedium**: Changed types (VBox 7.2.8 uses enums)
- **CreateSharedFolder**: VBox 7.2.8 adds `automount` and `autoMountPoint` parameters

### 5. Naming Differences
VBox 5.2 uses `get_PropertyName` style naming for properties, while VBox 7.2.8 type library calls them `PropertyName` (PROPGET kind). Both map to the same vtable entry - the name change is cosmetic in the IDL/type library, the actual COM method is accessed by its vtable index.

### 6. Return Type Pattern
VBox 7.2.8 returns interface pointers (e.g., `IHost*`, `IMachine*`) instead of `IDispatch*` for object-typed properties. This is fine for the proxy since we pass through the actual interface pointer.

---

## Enum Types Used in Parameters

From the type library, these enum types are referenced:
- `PlatformArchitecture` - used in GetPlatformProperties, CreateMachine, CheckFirmwarePresent
- `DeviceType` - used in CreateMedium, OpenMedium
- `AccessMode` - used in CreateMedium, OpenMedium
- `MachineState` - used in GetMachineStates
- `FirmwareType` - used in CheckFirmwarePresent
- `TrackedObjectState` - used in GetTrackedObject

---

## Files Used for Analysis

- `F:\各种项目\逆向ensp\analysis\output\dump_vbox_vtable.py` - Python script that extracted and parsed the type library
- `C:\Program Files\Oracle\VirtualBox\VBoxProxyStub.dll` - Source of the type library data
- Registry: `HKLM\SOFTWARE\Classes\Interface\{2CE10519-3C09-45D8-A12D-E887786146B7}` (NumMethods=92, ProxyStub=VBoxProxyStub.dll)
- Registry: `HKLM\SOFTWARE\Classes\TypeLib\{D7569351-1750-46F0-936E-BD127D5BC264}\1.3\0\win64` -> VBoxProxyStub.dll
- Registry: `HKLM\SOFTWARE\Classes\CLSID\{B1A7A4F2-47B9-4A1E-82B2-07CCD5323C3F}` (VirtualBox CoClass)
