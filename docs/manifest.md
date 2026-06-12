# 清单 —— 哪些是承重件

本项目对一份原装 eNSP + VirtualBox 安装所做的每一处改动，以及它是 eNSP 在 7.2
上运行所**必需**的，还是仅供**诊断**。

图例：
- **REPLACED（替换）** —— 某文件被换成我们的。
- **PATCHED（打补丁）** —— 就地编辑某个已有文件（可逆）。
- **REGISTRY（注册表）** —— 改某个注册表值。
- **承重** —— 拿掉它 eNSP 就失败。
- **诊断** —— 只做记录/观察；省略或剥离都安全。

## 承重件

| # | 改动 | 类型 | 位置 | 为什么必需 |
|---|------|------|------|-----------|
| 1 | `VBox52.dll` | REPLACED | `…\Huawei\eNSP\tools\VBox52.dll` | COM/vtable 垫片。eNSP_VBoxServer.exe 加载它并调用 `GetVBoxInstance()`；它在真实 7.2 对象之上呈现一个 5.2 `IVirtualBox`。同时也充当 COM InprocServer32 类厂。 |
| 2 | `VAR_Plugin.dll`（ar1000v） | PATCHED | `…\Huawei\eNSP\plugin\ar1000v\VAR_Plugin.dll` | AR 路由器插件通过写死的 5.2 vtable 偏移去调用真实的 7.2 `IVirtualBox`。没有这处 28 站点重映射补丁，AR 会打到错误的方法、一启动就崩。独立于 #1——AR 两者都需要。 |
| 3 | 版本伪装 | REGISTRY | `HKLM\…\Oracle\VirtualBox` `Version`/`VersionExt`（两个视图） | eNSP 在 COM 之前的版本闸门拒绝任何非 `5.2.x` 的版本。字符串读作 `5.2.44`；二进制其实是 `7.2.8.173730`。 |
| 4 | CLSID InprocServer32 | REGISTRY | `CLSID\{B1A7A4F2-…}\InprocServer32`（两个视图） | 把 `CLSID_VirtualBox` 的 32 位进程内服务器重指到 `VBox52.dll`，这样 eNSP 的 `CoCreateInstance` 加载的是我们的类厂，而非 VBox 原生的 proxy/stub。 |

四项都已对照一份活的、能工作的安装核验过（AR 起到 `<Huawei>`，AC6605 起到
`<AC6605>`）。

### 进程内版本伪装（#1 的一部分）

在 `VBox52.dll` 内部，vtable 槽位 `[3]`–`[6]`（`get_version`、
`get_versionNormalized`、`get_revision`、`get_packageType`）返回写死的
`5.2.22` 而不转发。这是**承重的**：它是版本伪装的后半段，在 eNSP 已握住对象
*之后*读取（注册表那半段是在 COM *之前*读的）。见 `src/spoof_thunks.cpp`。

## 诊断件（非承重）

| 改动 | 位置 | 它做什么 |
|------|------|----------|
| `CreateProcessW` IAT 钩子 | `VBox52.dll` 内部 | 只观察。把每个子进程命令行记到 `C:\vbox\vboxmanage_wrapper.log`，然后**原封不动**调用真实的 `CreateProcessW`。不改写参数、不重定向目标。 |
| VEH 崩溃记录器 | `VBox52.dll` 内部 | 只观察的向量化异常处理器。记录异常；从不改变控制流。 |
| `VBoxManage.exe` 包装器 | `…\Oracle\VirtualBox\`（一份能工作的安装里可能有一个） | 可选的透传，记录调用并原样转发给 `VBoxManage_real.exe`。eNSP 的 `clonevm`/`modifyvm`/`startvm` 都是原生 7.2.8 命令，对着真实二进制跑得好好的。**源码不在本仓库，这里也没有任何东西依赖它。** |

这些拿掉都不影响 eNSP 能否运行。它们存在只是为了在调试启动期间让启动链路可
观察。

## 前提（用户自备，不随仓库分发）

| 要求 | 备注 |
|------|------|
| 已装 VirtualBox **7.2.x** | 真实二进制必须是 7.2；只有注册表在假装 5.2。 |
| 已装华为 eNSP | 我们就地修改*你的*那份拷贝;eNSP 主程序需自行安装,本仓库不分发。 |
| 32 位 MSVC 工具链 | 用来从 `src/` 重新编译 `VBox52.dll`（见 `build/build.bat`）。预编译的 `build/VBox52.dll` 是我们自己的编译产物。 |

## 还原 / 卸载

| 改动 | 如何撤销 |
|------|----------|
| #1 `VBox52.dll` | 通过对 VBox 7.2 跑**修复**（或重装）来还原 VirtualBox 原生的 COM 注册——见 `registry/README.md`。把我们的 DLL 从 `eNSP\tools\` 移除。 |
| #2 `VAR_Plugin.dll` | `python patches\patch_var_plugin.py --restore <路径>`（或还原补丁器写的 `.bak`）。往返校验过能精确复现原始哈希。 |
| #3 版本伪装 | `reg import registry\99_uninstall.reg` —— 还原回 `7.2.8` / `7.2.8r173730`。 |
| #4 CLSID InprocServer32 | 故意**不**作为 `.reg` 分发（正确的值随 Oracle 构建版本而异）。VBox **修复**/重装会把它改回原生 proxy/stub。见 `registry/README.md`。 |

## 法务立场

本仓库装的是**我们**的源码（`src/`）、补丁器（`patches/`）、`.reg` 文件
（`registry/`），以及我们自己编译的 `build/VBox52.dll`。华为 eNSP 与 Oracle 的
主程序不在其中,需自行安装;整合包 `installer/payload/` 另附少量配套文件以
省去手工步骤。补丁器就地编辑*你的*那份拷贝，且完全可逆。
