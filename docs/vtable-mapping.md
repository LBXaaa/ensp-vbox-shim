# IVirtualBox vtable 映射（5.2 → 7.2）

`src/` 里的代理对外呈现一张 **5.2 形状的 `IVirtualBox` vtable**，并把每个槽位
按重映射后的索引转发给**真实的 7.2.8 对象**。本文件是权威的槽位表；它直接从
`src/vbox52_proxy.cpp`（`g_vbox52_vtable[]`）和 `src/vbox52_thunks.asm` 誊录而来。

## 为什么布局不同

VBox 7.x **不是** 5.2 的统一平移：

1. **基础接口不同。** 5.2 `IVirtualBox : IUnknown`（3 个基础槽位：
   QueryInterface、AddRef、Release）。7.2 `IVirtualBox : IDispatch`（7 个基础
   槽位：再加 GetTypeInfoCount、GetTypeInfo、GetIDsOfNames、Invoke）。基础之后
   的一切都平移 +4。
2. **表中间插入了新属性** —— `guestOSFamilies`、`hostOnlyNetworks`、
   `cloudNetworks`、`cloudProviderManager`。
3. **既插入了新方法，又把原有方法重排了序** —— 例如 5.2 `createDHCPServer` 是
   第 3 个方法，但在 7.2 里是第 22 个。新增方法共 17 个。

所以越过 `get_guestOSTypes` 之后，偏移就不再是恒定的 `+4` 了。下面每个槽位都
单独映射。

## 代理 vtable（eNSP 看到的）

53 个槽位，`[0]`–`[52]`。三类槽位：

- **spoof（伪装）** —— 本地处理，返回写死的 5.2 字符串，**不**碰真实对象
  （`src/spoof_thunks.cpp`）。
- **forward → 7.2[N]（转发）** —— 裸 thunk 从 `[ecx+12]` 读出 `realVBox`，按
  索引 `N` 尾跳真实 7.2 vtable（`src/vbox52_thunks.asm`，`UNI_THUNK_DIAG`）。
- **wrap（包裹）** —— 转发，然后把返回/传入的 `IMachine*` 包进一个
  `MachineProxy`，让调用方也拿到一个 5.2 形状的 machine
  （`src/imachine_entries.asm`）。

| 5.2 槽位 | 方法 | 类别 | → 7.2 |
|---:|---|---|---:|
| 0  | QueryInterface | IUnknown（转发） | 0 |
| 1  | **clone 前置条件探测** | 特殊（`ret 0xc`，**非** AddRef） | — |
| 2  | Release | IUnknown（转发） | 2 |
| 3  | get_version | 伪装 `"5.2.22"` | — |
| 4  | get_versionNormalized | 伪装 `"5.2.22"` | — |
| 5  | get_revision | 伪装 `"22"` | — |
| 6  | get_packageType | 伪装 `"5.2.22"` | — |
| 7  | get_APIVersion | 转发 | 11 |
| 8  | get_APIRevision | 转发 | 12 |
| 9  | get_homeFolder | 转发 | 13 |
| 10 | get_settingsFilePath | 转发 | 14 |
| 11 | get_host | 转发 | 15 |
| 12 | get_systemProperties | 转发 | 16 |
| 13 | get_machines | 转发 | 17 |
| 14 | get_machineGroups | 转发 | 18 |
| 15 | get_hardDisks | 转发 | 19 |
| 16 | get_DVDImages | 转发 | 20 |
| 17 | get_floppyImages | 转发 | 21 |
| 18 | get_progressOperations | 转发 | 22 |
| 19 | get_guestOSTypes | 转发 | 23 |
| 20 | get_sharedFolders | 转发 | 25 |
| 21 | get_performanceCollector | 转发 | 26 |
| 22 | get_DHCPServers | 转发 | 27 |
| 23 | get_NATNetworks | 转发 | 28 |
| 24 | get_eventSource | 转发 | 29 |
| 25 | get_extensionPackManager | 转发 | 30 |
| 26 | get_internalNetworks | 转发 | 31 |
| 27 | get_genericNetworkDrivers | 转发 | 33 |
| 28 | composeMachineFilename | 转发 | 36 |
| 29 | createAppliance | 转发 | 44 |
| 30 | createDHCPServer | 转发 | 57 |
| 31 | createMachine | 转发 | 38 |
| 32 | createMedium | 转发 | 46 |
| 33 | createNATNetwork | 转发 | 60 |
| 34 | createSharedFolder | 转发 | 51 |
| 35 | createUnattendedInstaller | 转发 | 45 |
| 36 | findDHCPServerByNetworkName | 转发 | 58 |
| 37 | findMachine | **包裹**（IMachine 返回值） | 41 |
| 38 | findNATNetworkByName | 转发 | 61 |
| 39 | getExtraData | 转发 | 54 |
| 40 | getExtraDataKeys | 转发 | 53 |
| 41 | getGuestOSType | 转发 | 48 |
| 42 | getMachineStates | 转发 | 43 |
| 43 | getMachinesByGroups | 转发 | 42 |
| 44 | openMachine | **包裹**（IMachine 返回值） | 39 |
| 45 | openMedium | 转发 | 47 |
| 46 | registerMachine | **包裹**（IMachine 入参） | 40 |
| 47 | removeDHCPServer | 转发 | 59 |
| 48 | removeNATNetwork | 转发 | 62 |
| 49 | removeSharedFolder | 转发 | 52 |
| 50 | setExtraData | 转发 | 55 |
| 51 | setSettingsSecret | 转发 | 56 |
| 52 | checkFirmwarePresent | 转发 | 70 |

### 特殊槽位说明

- **槽位 [1] 是 clone 前置条件探测，不是 AddRef。** 实际上 eNSP 通过这个对象的
  *唯一*调用就是槽位 [1]：一个带三个栈参、`ret 0xc` 的 `__thiscall`，形状为
  `HRESULT m(this, BSTR base, BSTR snapshot, HRESULT* pOut)`。该 thunk 转发给
  `helper_clone_check(realVBox, base, snap, pOut)`。在这里放 AddRef（`ret 4` 的
  形状）会让 eNSP 的栈漂移 8 字节并崩溃——这个槽位契约是靠实测复原的。因此
  `AddRef` 在代理 vtable 里**没有**活动槽位（asm 里存在一个极简的 `thunk_AR`，
  但未被使用）。
- **槽位 [3]–[6] 在本地伪装。** 把 `get_version` 转发给真实对象会回答
  `7.2.8`；而 eNSP 必须读到 `5.2.x`。这是版本伪装的进程内那一半（注册表那一半
  在 `registry/`）。
- **槽位 [37]/[44]/[46] 包裹 `IMachine`。** `IMachine` 有同样的 5.2→7.2 漂移；
  见下文。

## IMachine 包裹

`findMachine`/`openMachine` 返回一个 `IMachine*`，而 `registerMachine` 接收一
个。返回的 7.2 machine 被包进一个 `MachineProxy`（`src/imachine_entries.asm`）：

```
MachineProxy:  +0 vtable(5.2 形状)   +8 真实 7.2 IMachine   +12 逐槽 7.2 索引映射表
```

与 `IVirtualBox`（每槽一段手写 thunk）不同，`IMachine` 的 thunk（`im_e_N`）是
**查表驱动**的：每段从 `[this+8]` 读出真实 machine、从 `map[N]`（`[this+12]`）
读出目的地 7.2 索引，然后尾跳。**当前实现的告诫**：这张表是一刀切的 `N+4`
（`src/vbox52_proxy.cpp` 的 `g_imachine_map[i] = i + 4`），**并未**像上面
`IVirtualBox` 那样逐槽重映射。`IMachine` 自身在 5.2→7.2 间同样有重排，所以 +4
理论上不正确；实测未崩，只因 eNSP 当前唯一触达的是 `IVirtualBox` 的 vtable[1]
clone 探测，`findMachine`/`openMachine` 的 `IMachine` 包裹路径尚未被真正调用。
若将来 eNSP 开始在返回的 machine 上调方法，这里需改成逐槽表。

## 参考：完整的 7.2.8 IVirtualBox 布局

目的地一侧，用于交叉核对 `→ 7.2` 那一列。`IDispatch` 基础 `[0]`–`[6]`；属性
`[7]`–`[35]`；方法 `[36]`–`[73]`。**加粗** = 7.x 新增（无 5.2 对应）。

| 7.2 | 方法 | 7.2 | 方法 |
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

## 与 VAR_Plugin 补丁的关系

AR 插件通过写死的 **5.2** 偏移直接调用真实的 7.2 `IVirtualBox`，所以它需要把
*同一套*重映射作为字节补丁烤进去。`patches/var_plugin_ar1000v.md` 里的位移表
正是上面那一列 `→ 7.2`，以 `槽位 × 4` 表达（例如 `findMachine` 37→41 ⇒ 位移
`0x94`→`0xA4`）。该插件只引用了方法中的一个子集（`createSharedFolder` [34] 到
`checkFirmwarePresent` [52]），所以补丁里只出现那些槽位。
