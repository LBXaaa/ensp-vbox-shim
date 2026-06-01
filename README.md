# ensp-vbox-shim

让原版 **华为 eNSP** 直接跑在 **VirtualBox 7.x** 上，底层是真实vbox
7.2.8 虚拟机引擎，全程不降级组件。

## 为什么做这个

广东省职业技能等级认定《信息通信网络运行管理员》中级工考试，要求在原版
eNSP 上操作。可现实是：eNSP 依赖的是 VirtualBox **5.2**，但本机刚需
WSL2/Hyper-V——只要开启了这些虚拟化组件，VBox 5.2 在现代 Windows（Win11、
Win10 24H2 及以上）上**根本装不上**；而这些组件一个都动不得，5.2 这条路就此
堵死。

网上流传的那些办法——降级 VirtualBox、改注册表、打补丁、换用 eNSP Pro——
大多要么挑系统版本，要么治标不治本，要么和现有环境冲突，要么干脆难以获取，
没一个撑得起稳定备考。

于是有了这套二进制 COM 垫片：让原版 eNSP 直接运行在 VirtualBox 7.x 上，既不
降级任何组件，也不动本机的 WSL2/Hyper-V。

拦路的技术问题有两道：eNSP 是针对 VBox 5.2 的 COM 接口编译的，而 7.x 的接口
和 5.2 **二进制不兼容**（原有方法被重新排序，还插入了一批新方法）；此外 eNSP
启动时会**硬性检查版本号、只认 `5.2.x`**。这套垫片就是来填这道缝的——对 eNSP
假装成 5.2，背地里把每一次调用翻译给真正的 7.2.8。

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
| [`installer/`](installer/) | **一键整合包**：双击 `安装.bat` 自动检测路径并打补丁(推荐普通用户用) |
| [`src/`](src/)         | 垫片源码：`vbox52_proxy.cpp`、`vbox52_thunks.asm`、`spoof_thunks.cpp`、`imachine_entries.asm`、`vbox52.def` |
| [`build/`](build/)     | `build.bat`（32 位 MSVC）和我们预编译好的 `VBox52.dll` |
| [`patches/`](patches/) | `patch_var_plugin.py` 及 AR 插件补丁的规格说明 |
| [`registry/`](registry/) | `.reg` 文件：版本伪装、CLSID 劫持、卸载 |
| [`docs/`](docs/)       | 架构、vtable 映射、承重件清单 |
| [`analysis/`](analysis/) | 支撑这一切的逆向脚本与发现 |

## 安装

### 一键整合包(推荐)

不想手动敲命令,用 [`installer/`](installer/):

1. 先装好原版 eNSP 和官方 VirtualBox 7.2.x;
2. 双击 **`installer\安装.bat`**,UAC 弹窗点"是";
3. 它会自动检测 eNSP/VBox 装在哪、拷垫片 DLL、写版本伪装、按真实路径生成
   CLSID 项、给 AR 插件打补丁,4 步全程无需手动指定路径。

还原:双击 **`installer\卸载.bat`**。只想看当前状态不改动:
`install.ps1 -Check`。详见 [installer/README.md](installer/README.md)。

### 手动安装

想完全掌控每一步,或要自行重新编译,前提:已经装好 **VirtualBox 7.2.x** 和
**华为 eNSP**;自行编译还需要一套 32 位 MSVC 工具链。注册表和 `Program Files`
的改动需要管理员权限。

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
