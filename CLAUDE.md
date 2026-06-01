<!-- VBOX_SDK_START -->
## VBox52.dll — VirtualBox SDK 接口参考

### VBox 5.2 IVirtualBox vtable 布局（eNSP 的期望）

IUnknown 基础（[0]-[2]）：[0] QI, [1] AddRef, [2] Release

属性（get_XXX，顺序固定）：
| 5.2 idx | 方法 | 返回类型 | 说明 |
|---------|------|---------|------|
| 3 | get_version | BSTR | 版本号 "5.2.22" |
| 4 | get_versionNormalized | BSTR | 标准化版本 |
| 5 | get_revision | ULONG | 构建修订号 |
| 6 | get_packageType | BSTR | 包类型 |
| 7 | get_APIVersion | BSTR | API 版本 |
| 8 | get_APIRevision | LONG64 | API 修订号 |
| 9 | get_homeFolder | BSTR | 全局设置目录 |
| 10 | get_settingsFilePath | BSTR | 配置文件路径 |
| 11 | get_host | IHost* | 宿主机对象 |
| 12 | get_systemProperties | ISystemProperties* | 系统属性 |
| 13 | get_machines[] | IMachine[] | 注册的 VM 列表 |
| 14 | get_machineGroups[] | BSTR[] | 机器组名列表 |
| 15 | get_hardDisks[] | IMedium[] | 已知硬盘列表 |
| 16 | get_DVDImages[] | IMedium[] | 光盘镜像列表 |
| 17 | get_floppyImages[] | IMedium[] | 软盘镜像列表 |
| 18 | get_progressOperations[] | IProgress[] | 进度操作列表 |
| 19 | get_guestOSTypes[] | IGuestOSType[] | 已知客户机 OS 类型 |
| 20 | get_sharedFolders[] | ISharedFolder[] | 全局共享文件夹 |
| 21 | get_performanceCollector | IPerformanceCollector* | 性能收集器 |
| 22 | get_DHCPServers[] | IDHCPServer[] | DHCP 服务器 |
| 23 | get_NATNetworks[] | INATNetwork[] | NAT 网络 |
| 24 | get_eventSource | IEventSource* | 事件源 |
| 25 | get_extensionPackManager | IExtPackManager* | 扩展包管理器 |
| 26 | get_internalNetworks[] | BSTR[] | 内部网络名列表 |
| 27 | get_genericNetworkDrivers[] | BSTR[] | 通用网络驱动名列表 |

方法（顺序固定）：
| 5.2 idx | 方法 | 返回类型 | 说明 |
|---------|------|---------|------|
| 28 | composeMachineFilename | BSTR | 生成 VM 配置文件路径 |
| 29 | createAppliance | IAppliance* | 创建 OVF 设备对象 |
| 30 | createDHCPServer | IDHCPServer* | 创建 DHCP 服务器 |
| 31 | createMachine | IMachine* | 创建新虚拟机 |
| 32 | createMedium | IMedium* | 创建新存储介质 |
| 33 | createNATNetwork | INATNetwork* | 创建 NAT 网络 |
| 34 | createSharedFolder | void | 创建全局共享文件夹 |
| 35 | createUnattendedInstaller | IUnattended* | 创建无人值守安装器 |
| 36 | findDHCPServerByNetworkName | IDHCPServer* | 按网络名查找 DHCP |
| 37 | findMachine | IMachine* | 按名称/UUID 查找 VM |
| 38 | findNATNetworkByName | INATNetwork* | 按名称查找 NAT |
| 39 | getExtraData | BSTR | 获取扩展数据 |
| 40 | getExtraDataKeys[] | BSTR[] | 获取所有扩展数据键 |
| 41 | getGuestOSType | IGuestOSType* | 获取客户机 OS 类型 |
| 42 | getMachineStates[] | MachineState[] | 获取多台 VM 状态 |
| 43 | getMachinesByGroups[] | IMachine[] | 按组获取 VM 列表 |
| 44 | openMachine | IMachine* | 从配置文件打开 VM |
| 45 | openMedium | IMedium* | 打开已有存储介质 |
| 46 | registerMachine | void | 注册 VM |
| 47 | removeDHCPServer | void | 删除 DHCP 服务器 |
| 48 | removeNATNetwork | void | 删除 NAT 网络 |
| 49 | removeSharedFolder | void | 删除共享文件夹 |
| 50 | setExtraData | void | 设置扩展数据 |
| 51 | setSettingsSecret | void | 解锁密码数据 |
| 52 | checkFirmwarePresent | BOOL | 检查固件是否存在 |

VBox 5.2 总 vtable 入口：3（IUnknown）+ 25（属性）+ 21（方法）= **49 个入口（[0]-[48]）**

---

### VBox 7.2.8 IVirtualBox vtable 布局（目标接口）

IDispatch 基础（[0]-[6]）：QI, AddRef, Release, GetTypeInfoCount, GetTypeInfo, GetIDsOfNames, Invoke

属性（[7]-[35]，共 29 个）：
| 7.x idx | 方法 | 返回类型 | 对应 5.2 | 说明 |
|---------|------|---------|---------|------|
| 7 | get_version | BSTR | [3] | |
| 8 | get_versionNormalized | BSTR | [4] | |
| 9 | get_revision | ULONG | [5] | |
| 10 | get_packageType | BSTR | [6] | |
| 11 | get_APIVersion | BSTR | [7] | |
| 12 | get_APIRevision | LONG64 | [8] | |
| 13 | get_homeFolder | BSTR | [9] | |
| 14 | get_settingsFilePath | BSTR | [10] | |
| 15 | get_host | IHost* | [11] | |
| 16 | get_systemProperties | ISystemProperties* | [12] | |
| 17 | get_machines[] | IMachine[] | [13] | |
| 18 | get_machineGroups[] | BSTR[] | [14] | |
| 19 | get_hardDisks[] | IMedium[] | [15] | |
| 20 | get_DVDImages[] | IMedium[] | [16] | |
| 21 | get_floppyImages[] | IMedium[] | [17] | |
| 22 | get_progressOperations[] | IProgress[] | [18] | |
| 23 | get_guestOSTypes[] | IGuestOSType[] | [19] | |
| 24 | get_guestOSFamilies[] | BSTR[] | **新增** | 客户机 OS 系列 |
| 25 | get_sharedFolders[] | ISharedFolder[] | [20] | |
| 26 | get_performanceCollector | IPerformanceCollector* | [21] | |
| 27 | get_DHCPServers[] | IDHCPServer[] | [22] | |
| 28 | get_NATNetworks[] | INATNetwork[] | [23] | |
| 29 | get_eventSource | IEventSource* | [24] | |
| 30 | get_extensionPackManager | IExtPackManager* | [25] | |
| 31 | get_internalNetworks[] | BSTR[] | [26] | |
| 32 | get_hostOnlyNetworks[] | IHostOnlyNetwork[] | **新增** | 主机专用网络 |
| 33 | get_genericNetworkDrivers[] | BSTR[] | [27] | |
| 34 | get_cloudNetworks[] | ICloudNetwork[] | **新增** | 云网络 |
| 35 | get_cloudProviderManager | ICloudProviderManager* | **新增** | 云提供商管理器 |

方法（[36]-[73]，共 38 个）：
| 7.x idx | 方法 | 返回类型 | 对应 5.2 | 说明 |
|---------|------|---------|---------|------|
| 36 | composeMachineFilename | BSTR | [28] | |
| 37 | getPlatformProperties | IPlatformProperties* | **新增** | |
| 38 | createMachine | IMachine* | [31] | 顺序变了！ |
| 39 | openMachine | IMachine* | [44] | |
| 40 | registerMachine | void | [46] | |
| 41 | findMachine | IMachine* | [37] | |
| 42 | getMachinesByGroups[] | IMachine[] | [43] | |
| 43 | getMachineStates[] | MachineState[] | [42] | |
| 44 | createAppliance | IAppliance* | [29] | 顺序变了！ |
| 45 | createUnattendedInstaller | IUnattended* | [35] | |
| 46 | createMedium | IMedium* | [32] | |
| 47 | openMedium | IMedium* | [45] | |
| 48 | getGuestOSType | IGuestOSType* | [41] | |
| 49 | getGuestOSSubtypesByFamilyId[] | BSTR[] | **新增** | |
| 50 | getGuestOSDescsBySubtype[] | BSTR[] | **新增** | |
| 51 | createSharedFolder | void | [34] | |
| 52 | removeSharedFolder | void | [49] | |
| 53 | getExtraDataKeys[] | BSTR[] | [40] | |
| 54 | getExtraData | BSTR | [39] | |
| 55 | setExtraData | void | [50] | |
| 56 | setSettingsSecret | void | [51] | |
| 57 | createDHCPServer | IDHCPServer* | [30] | 顺序变了！ |
| 58 | findDHCPServerByNetworkName | IDHCPServer* | [36] | |
| 59 | removeDHCPServer | void | [47] | |
| 60 | createNATNetwork | INATNetwork* | [33] | |
| 61 | findNATNetworkByName | INATNetwork* | [38] | |
| 62 | removeNATNetwork | void | [48] | |
| 63 | createHostOnlyNetwork | IHostOnlyNetwork* | **新增** | |
| 64 | findHostOnlyNetworkByName | IHostOnlyNetwork* | **新增** | |
| 65 | findHostOnlyNetworkById | IHostOnlyNetwork* | **新增** | |
| 66 | removeHostOnlyNetwork | void | **新增** | |
| 67 | createCloudNetwork | ICloudNetwork* | **新增** | |
| 68 | findCloudNetworkByName | ICloudNetwork* | **新增** | |
| 69 | removeCloudNetwork | void | **新增** | |
| 70 | checkFirmwarePresent | BOOL | [52] | |
| 71 | findProgressById | IProgress* | **新增** | |
| 72 | getTrackedObject | (unknown) | **新增** | |
| 73 | getTrackedObjectIds[] | BSTR[] | **新增** | |

### 关键结论

**vtable 不是简单的 +4 偏移！** API 布局变化：
- IDispatch 插入：所有方法偏移 +4
- 新增 4 个属性（guestOSFamilies、hostOnlyNetworks、cloudNetworks、cloudProviderManager）
- 新增 17 个方法，**_且原有方法被重新排序_**（不是简单追加）
- 例如 createDHCPServer 在 5.2 中是第 3 个方法，在 7.x 中移到第 22 个

需要根据上表逐一映射。vtable 索引超出 7（get_guestOSTypes）后偏移不一致，不能统一加 4。

### 当前 proxy 文件

- vbox52_proxy.cpp — 主 proxy 代码
- vbox52_thunks.asm — ASM thunk，vtable 索引已按 SDK 修正
- build_with_trace.bat — 编译脚本
<!-- VBOX_SDK_END -->
