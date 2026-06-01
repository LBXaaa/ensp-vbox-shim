# ensp-vbox-shim

让 **华为 eNSP** 跑在 **VirtualBox 7.2.x** 上，而不是它自带的那套古老的
VirtualBox 5.2 —— 底层是原封不动的真实 7.2 虚拟机引擎。

eNSP 是针对 VirtualBox **5.2** 的 COM API 编译的。VBox 5.2 已经无法在现代
Windows 上正常安装；VBox 7.2 可以，但它的 COM 接口与 5.2 **二进制不兼容**
（7.x 的 `IVirtualBox` 派生自 `IDispatch`，插入了新方法，并且把原有方法重新
排了序）。更麻烦的是，eNSP 在调用 COM 之前还会**硬性拒绝**任何不是 `5.2.x`
的版本。

本项目用一个小巧的 COM/vtable 垫片，加上一处可逆的字节补丁，把这道鸿沟补上：
eNSP 以为自己在跟 5.2 对话，实际干活的是一套未经改动的 VirtualBox 7.2.8。
已端到端验证：一台 AR 路由器能启动到 `<Huawei>` 命令行，一台 AC6605 能启动到
`<AC6605>`。

## 工作原理

三座承重的桥（完整细节见 [docs/](docs/)）：

1. **`VBox52.dll`** —— 一个 32 位垫片，部署到 `eNSP\tools\`。它在活的 7.2
   对象之上，对外呈现一套 **5.2 形状的 `IVirtualBox` vtable**，把每个槽位转发
   到正确的（重映射后的）7.2 方法。它有两条进入路径：eNSP 的
   `GetVBoxInstance()` 导出调用，以及一个 COM `InprocServer32` 类厂。
2. **版本伪装** —— 注册表里的 `Version`/`VersionExt` 读出来是 `5.2.44`，好让
   eNSP 的版本闸门放行（二进制其实是 `7.2.8.173730`）；垫片在进程内也会对
   `get_version` 回答 `5.2.22`。
3. **`VAR_Plugin.dll` 补丁** —— AR 路由器插件会通过写死的 5.2 vtable 偏移直接
   调用 `IVirtualBox`；一处 28 个站点、29 字节的可逆补丁把这些偏移重映射到
   7.2。

```
eNSP_Client.exe → eNSP_VBoxServer.exe → VBox52.dll (垫片) → VBoxSVC.exe 7.2.8
```

完整全貌见 [docs/architecture.md](docs/architecture.md)，权威槽位对照表见
[docs/vtable-mapping.md](docs/vtable-mapping.md)，哪些是承重件、哪些只是诊断件
见 [docs/manifest.md](docs/manifest.md)。

## 仓库结构

| 目录 | 内容 |
|------|------|
| [`src/`](src/)         | 垫片源码：`vbox52_proxy.cpp`、`vbox52_thunks.asm`、`spoof_thunks.cpp`、`imachine_entries.asm`、`vbox52.def` |
| [`build/`](build/)     | `build.bat`（32 位 MSVC）和我们预编译好的 `VBox52.dll` |
| [`patches/`](patches/) | `patch_var_plugin.py` 及 AR 插件补丁的规格说明 |
| [`registry/`](registry/) | `.reg` 文件：版本伪装、CLSID 劫持、卸载 |
| [`docs/`](docs/)       | 架构、vtable 映射、承重件清单 |
| [`analysis/`](analysis/) | 支撑这一切的逆向脚本与发现 |

## 安装

前提：已经装好 **VirtualBox 7.2.x** 和 **华为 eNSP**；若要自行重新编译，还需要
一套 32 位 MSVC 工具链。注册表和 `Program Files` 的改动需要管理员权限。

```bat
:: 1. 垫片 —— 编译（或直接用 build\VBox52.dll）后拷进 eNSP
build\build.bat
copy build\VBox52.dll "C:\Program Files\Huawei\eNSP\tools\VBox52.dll"

:: 2. 注册表 —— 先版本伪装，再 CLSID 劫持
reg import registry\01_version_spoof.reg
reg import registry\02_clsid_inprocserver.reg

:: 3. AR 插件补丁（会先写一份 .bak）
python patches\patch_var_plugin.py "C:\Program Files\Huawei\eNSP\plugin\ar1000v\VAR_Plugin.dll"
```

然后启动 eNSP，拉起一台设备即可。要还原，见
[registry/README.md](registry/README.md) 以及
`python patches\patch_var_plugin.py --restore …`。

## 这个仓库装了什么、不装什么

它装的是**我们自己**的源码、补丁器、`.reg` 文件，以及我们自己编译出来的
`VBox52.dll`。它**不**包含任何华为或 Oracle 的二进制文件。补丁器是就地修改
**你**已经装好的那份拷贝，且完全可逆（已用哈希往返校验过）。

## 法务说明

本项目与 **华为 eNSP** 和 **Oracle VM VirtualBox** 互操作，二者均归各自所有者
所有；本仓库不重新分发其中任何一方的二进制文件。下面的开源许可只覆盖本仓库里
我们原创的代码（垫片源码、补丁器、注册表文件和分析脚本）。

## 许可证

我们的代码采用 **Mozilla Public License 2.0（MPL-2.0）** —— 见
[LICENSE](LICENSE)。VirtualBox 与 eNSP 归各自所有者所有；本项目与它们互操作，
但不重新分发任何一方。
