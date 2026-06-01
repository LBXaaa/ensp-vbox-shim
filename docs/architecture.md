# 架构

`ensp-vbox-shim` 如何让华为 eNSP（为 VirtualBox **5.2** 而编译）在底层驱动一套
原封不动的真实 VirtualBox **7.2.8**。

## 问题所在

eNSP 是针对 VirtualBox 5.2 的 COM API 编译的。VBox 5.2 无法在当前的 Windows
版本上干净安装，而 7.2.x 可以。可这两套 API *并非*二进制兼容：

- VBox 7.x 的 `IVirtualBox` 派生自 `IDispatch`（7 个基础槽位），而 5.2 派生自
  `IUnknown`（3 个基础槽位），于是每个方法都往后挪了 +4。
- 7.x 还**插入了新的属性/方法，并把原有的重新排了序**——越过
  `get_guestOSTypes` 之后，vtable 就不再是统一的 `+4` 平移了。见
  [vtable-mapping.md](vtable-mapping.md)。
- eNSP 会卡注册表里的版本字符串，凡不是 `5.2.x` 一律拒绝。

所以 eNSP 没法直接调用 7.2。垫片夹在中间，对外呈现一张 5.2 形状的表面，背后由
活的 7.2 服务器支撑。

## 启动链路

```
eNSP_Client.exe
  └─ eNSP_VBoxServer.exe              (32 位宿主进程)
       └─ LoadLibrary  tools\VBox52.dll          ← 我们的垫片
            └─ GetVBoxInstance()                  ← 我们的导出
                 └─ CoCreateInstance(CLSID_VirtualBox, CLSCTX_LOCAL_SERVER,
                                      IID_VBox7_IVirtualBox)
                      └─ VBoxSVC.exe              (真实的进程外 7.2.8 服务器)
```

eNSP 是 **32 位**的，所以它底下的一切都跑在 WOW64 里，读的是 `WOW6432Node`
注册表视图。

## 三座承重的桥

三座缺一不可。拆掉任意一座 eNSP 就跑不起来（版本闸门拒绝、COM 对象形状不对、
或 AR 路由器插件一启动就崩）。

### 1. 版本伪装（注册表）

`HKLM\SOFTWARE\[WOW6432Node\]Oracle\VirtualBox` 的 `Version`/`VersionExt` 被设为
`5.2.44` / `5.2.44r139111`。二进制其实是 `7.2.8.173730`；只有这些字符串在撒谎。
这让 eNSP 通过它在 COM 之前的版本闸门。见
[`registry/01_version_spoof.reg`](../registry/01_version_spoof.reg)。

垫片内部还有**第二处、进程内**的版本伪装：代理的 `get_version` /
`get_versionNormalized` / `get_revision` 这几个 vtable 槽位返回写死的
`5.2.22`，而不转发给真实对象（真对象会回答 `7.2.8`）。见
`src/spoof_thunks.cpp`。注册表那处是在 COM *之前*读的；进程内这处是在 eNSP 已
握住 `IVirtualBox` 指针*之后*读的。

### 2. VBox52.dll —— COM/vtable 垫片

一个 32 位 DLL，部署到 `…\Huawei\eNSP\tools\VBox52.dll`。它暴露**四个**导出：

| 导出 | 链接方式 | 谁调用它 |
|------|---------|----------|
| `GetVBoxInstance`   | `.def` + `__declspec(dllexport)` | eNSP_VBoxServer.exe，直接按名调用 |
| `DelVBoxInstance`   | `.def` + `__declspec(dllexport)` | eNSP_VBoxServer.exe 拆卸时 |
| `DllGetClassObject` | `#pragma … /export`              | COM，经 InprocServer32 劫持 |
| `DllCanUnloadNow`   | `#pragma … /export`              | COM（返回 `S_FALSE`，永不卸载） |

**两条进入路径，同一个代理对象。** 两条路径都终结于同一个结构：

- **导出路径：** `GetVBoxInstance()` → `CoCreateInstance(CLSCTX_LOCAL_SERVER,
  IID_VBox7_IVirtualBox)` → 包裹真实对象 → 返回代理视图。
- **COM 路径：** 注册表把 `CLSID_VirtualBox` 的 32 位 `InprocServer32` 重指到
  VBox52.dll（见
  [`registry/02_clsid_inprocserver.reg`](../registry/02_clsid_inprocserver.reg)）。
  此后一次 32 位的 `CoCreateInstance(CLSID_VirtualBox)` 就会加载我们，调用我们的
  `DllGetClassObject` → 返回 `g_factory` → `Factory_CreateInstance` 再调
  `CoCreateInstance(CLSID_VirtualBox, CLSCTX_LOCAL_SERVER, …)` 去够到真实的进程外
  7.2 `VBoxSVC.exe`（显式的 `CLSCTX_LOCAL_SERVER` 绕开我们自己的 InprocServer32，
  避免无限递归），然后包裹它。

**代理对象形状**（`src/vbox52_proxy.cpp`）：

```c
struct VBoxProxyView { const void** vtable; void* self1; void* self2; IUnknown* realVBox; };
//                     +0                    +4          +8          +12
struct VBoxProxyRoot { LONG refCount; VBoxProxyView view; };  // refCount 在 view-4 处
```

`vtable` 指向 `g_vbox52_vtable`，一张 **50 槽的 5.2 `IVirtualBox` 布局**。每个
槽位都是一段裸 thunk（`src/vbox52_thunks.asm`），从 `[ecx+12]` 读出
`realVBox`，再尾跳进**真实 7.2 vtable 中重映射后的索引**（例如 5.2
`createDHCPServer` 槽 30 → 7.2 索引 57）。逐槽完整映射见
[vtable-mapping.md](vtable-mapping.md)。

**IMachine 包裹。** `findMachine` / `openMachine` / `registerMachine` 返回或接收
`IMachine*`，它有着*同样*的 5.2→7.2 vtable 漂移。这些槽位用专门的 thunk，把真实
的 7.2 `IMachine` 包进一个 `MachineProxy`（`src/imachine_entries.asm`）：

```
MachineProxy:  +0 vtable   +8 realMachine   +12 逐槽 7.2 索引映射表
```

`im_e_N` 这些 thunk 从 `[this+8]` 读出真实 machine、从 `map[N]` 读出目的地 7.2
索引，然后尾跳——同样的重映射把戏，只不过改成了查表驱动，而不是每槽手写一段
thunk。

**IAT 钩子**（首次创建代理时装进宿主进程，`install_iat_hook`）：

- `ole32!CoGetClassObject` → 拦截 `CLSID_VirtualBox` 并交回 `g_factory`（代理类
  厂），这样进程内的 `CoGetClassObject` 也被桥接。一个 `g_factory_guard` 标志
  防止递归。
- `kernel32!CreateProcessW` → **只观察。** 把每个子进程命令行记到
  `C:\vbox\vboxmanage_wrapper.log`，然后**原封不动**调用真实的 `CreateProcessW`。
  它不改写参数、也不重定向目标。纯诊断；可忽略或删除。

进程级还装了一个**只观察**的 **VEH** 崩溃记录器：它记录每个异常，从不改变控制
流。

### 3. VAR_Plugin.dll 字节补丁（仅 AR 路由器）

`plugin\ar1000v\VAR_Plugin.dll` 插件**并非**事事都走代理——它自己握着一个真实
的 7.2 `IVirtualBox` 指针，并通过**写死的 5.2 vtable 偏移**去调用它。在 7.x 上
这些偏移会落到错误的方法（例如 5.2 `findMachine` 会打到 7.2
`getPlatformProperties`），AR 一启动就崩。

修法是一处 29 字节、28 个站点的就地补丁，只改写每个 `call [reg+disp]` 的位移
字节，把每个 5.2 槽位重映射到它的 7.2 槽位。文件大小不变，改动完全可逆。规格
与补丁器在 [`patches/`](../patches/)。这座桥与 VBox52.dll **互相独立**——AR 两者
都需要。

## 可选：VBoxManage.exe 包装器

一份能工作的安装里可能还有一个 `VBoxManage.exe` 垫片，它记录每次调用，再原样
转发给 `VBoxManage_real.exe`（真实的 7.2.8 命令行工具）。它是**诊断件，非承重
件**——eNSP 的 `clonevm` / `modifyvm` / `startvm` 都是原生 7.2.8 命令，对着真实
二进制跑得好好的。它的源码**不**在本仓库，这里也没有任何东西依赖它。

## 装什么、不装什么

本仓库装的是**我们**的源码、补丁器和 `.reg` 文件。它**不**包含任何华为或
Oracle 的二进制文件。`build/VBox52.dll` 是我们从 `src/` 自己编译出来的产物。要
还原成原装安装，见 [`registry/README.md`](../registry/README.md)（版本字符串）
和 `patches/`（`--restore`）。

逐文件的承重件拆解见 [manifest.md](manifest.md)。
