# 一键整合包 · installer/

让原版华为 eNSP 直接跑在 VirtualBox 7.x 上。**解压 → 双击 → 搞定**,自动检测 eNSP / VirtualBox 安装位置,无需手动改注册表或拷文件。

## 目录内容

| 文件 | 作用 |
|------|------|
| `安装.bat` | 安装入口。双击即可:打补丁 + 自动注册设备,一次搞定 |
| `卸载.bat` | 卸载/还原入口。双击即可,自动提权 |
| `注册设备.bat` | **后备**:仅当自动注册被跳过(右键用了别的管理员账户)时,用平时启动 eNSP 的账户双击它补做 |
| `install_all.ps1` | 编排器(被 `安装.bat` 调用):提权打补丁,再以登录用户身份注册设备 |
| `install.ps1` | 实际打补丁的脚本(被 `install_all.ps1` 提权调用,也被 `卸载.bat` 调用) |
| `register_vms.ps1` | 注册脚本(被 `install_all.ps1` 和 `注册设备.bat` 调用) |
| `payload/VBox52.dll` | 预编译好的 COM/vtable 垫片,安装时拷进 eNSP\tools\ |

## 怎么用

### 安装

1. 先装好**原版** eNSP 和**官方** VirtualBox 7.2.x(本仓库不附带它们)。
2. 双击 **`安装.bat`**。
3. 弹出 UAC 窗口点"是"(打补丁要写注册表 + 改 Program Files,需要管理员权限)。
4. 看窗口里的两步:第 1 步打补丁(4 项 ✓),第 2 步自动注册基础设备 VM。结束后启动 eNSP 拉一台设备试试。

`安装.bat` 一次把两件事都做了:**打补丁**(提权)和**注册设备 VM**(以登录账户身份)。
全程只需双击一次、UAC 只弹一次。

### 注册被跳过时(后备:`注册设备.bat`)

正常情况下 `安装.bat` 已自动完成注册,**不需要**再单独点 `注册设备.bat`。

只有一种情况会跳过自动注册:**右键用了"别的管理员账户"**运行安装(此时进程身份不
是平时启动 eNSP 的那个登录用户,自动注册会写进错误的用户配置、eNSP 反而看不到)。这时
安装窗口会黄字提示,请**用平时启动 eNSP 的账户**(不要用管理员)双击 **`注册设备.bat`**
补做。它扫 `vboxserver\` 下的基础盘(`AR_Base`、`WLAN_*_Base`),未注册的注册、已注册的
先注销再重注册一遍(清掉半坏的注册状态)。幂等、可逆——注销不加 `--delete`,不动磁盘。

这些基础设备 VM 是拖设备时的克隆源,没注册上设备就起不来——所以注册是必要的,只是现在默认
已被 `安装.bat` 自动做掉。

只想看会做什么、不改动:

```powershell
powershell -ExecutionPolicy Bypass -File register_vms.ps1 -Check
```

为什么注册这步不提权:VM 注册写入当前用户的 `.VirtualBox\VirtualBox.xml`,必须与启动 eNSP
的账户一致;用管理员跑可能写进别的账户、eNSP 反而看不到。`install_all.ps1` 正是为此设计——
打补丁那段提权,注册那段退回登录账户身份来跑。

### 卸载还原

双击 **`卸载.bat`**,会还原版本字符串、从 `.orig.bak` 还原 AR 插件与垫片 DLL。其中 `tools\`、`plugin\ngfw\tools\ngfw\` 两处有华为原文件的备份,会被还原回原版;eNSP 根目录、`vboxserver\` 两处的垫片是安装时新建的、无原文件备份,卸载时直接跳过(属正常)。CLSID 项需要手动跑一次 VBox 修复(见下方"卸载的最后一步")。

### 只检测不改动

想先看看当前机器是什么状态,不做任何改动:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Check
```

会打印 eNSP/VBox 路径、垫片 DLL 是否就位、注册表版本号、CLSID 指向、VAR_Plugin.dll 是出厂版还是已打补丁，并附一段**环境检测**（见下）。

### 环境检测（排查用，只读不改动）

安装时（以及 `-Check` 时）会自动打印一段环境快照，聚焦设备启动失败（error 40）的几类常见成因，**只读取、不改动系统**：

- **CPU / VT-x** —— 固件虚拟化是否开启、VMX 扩展是否可用（开了 Hyper-V/WSL 时固件项常报"未启用"，这是 hypervisor 接管所致，属正常）；
- **Hyper-V / WHP / 内存完整性(HVCI) / 虚拟机平台** —— 任一启用，VBox 7.x 会走 WHP 后端运行（eNSP 原配的 VBox 5 与 Hyper-V 冲突起不来，7.x 靠 WHP 才能与 Hyper-V/WSL/WSA 共存）。代价只是设备启动变慢（单台 3-5 分钟），**不是故障，无需关闭 Hyper-V**；
- **x86 VCRT** —— `VBox\x86\` 下的 `VCRUNTIME140.dll` / `MSVCP140.dll` 是否就位（缺它 → `0x800700C1` → error 40，安装步骤会补上）；
- **版本伪装** —— 注册表 `Oracle\VirtualBox\Version` 当前值。

这段同时显示在窗口里、也写进安装日志（`%TEMP%\ensp-vbox-shim-install.log`），设备起不来时先看它。

### 自动检测失败时手动指定路径

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -EnspDir "D:\Program Files\Huawei\eNSP" -VBoxDir "D:\Program Files\Oracle\VirtualBox"
```

## 它到底改了什么(安装的 4 步)

1. **部署垫片 DLL** —— 把 `payload\VBox52.dll` 覆盖到 eNSP 树内**全部 4 个加载位置**:`tools\`、`vboxserver\`、eNSP 根目录、`plugin\ngfw\tools\ngfw\`。每个位置先查 hash:已经是同一版本就跳过,否则备份原文件为 `.orig.bak` 后覆盖。

2. **写版本伪装** —— 注册表 `HKLM\SOFTWARE\Oracle\VirtualBox` 的 `Version` 改成 `5.2.44`(64 位 + 32 位 WOW6432Node 两个视图都写)。eNSP 启动时检查这个值,装的是 7.x 它会拒跑。

3. **劫持 CLSID InprocServer32** —— 把 `CLSID\{B1A7A4F2-...}\InprocServer32` 的默认值指向 `tools\VBox52.dll` 的实际路径。路径随 eNSP 安装位置动态生成。

4. **覆盖 AR 插件** —— 用 `payload\VAR_Plugin.dll`(预构建的已补丁版)直接覆盖 `plugin\ar1000v\VAR_Plugin.dll`,备份原文件为 `.orig.bak`。不再运行时打字节补丁。

四步详细原理见仓库 `docs/architecture.md`。

## 自动检测逻辑

**eNSP 目录** —— 先读卸载注册表里 DisplayName 含 `eNSP` 的项的 `InstallLocation`;找不到再回退到 `Program Files (x86)\Huawei\eNSP` 与 `Program Files\Huawei\eNSP`。最终都会校验该目录下确实有 `tools\` 子目录才算数。

**VirtualBox 目录** —— 读 `HKLM\SOFTWARE\Oracle\VirtualBox` 的 `InstallDir`(32/64 位视图都试),回退默认安装路径。

任一项检测失败,用 `-EnspDir` / `-VBoxDir` 手动指定即可。

## 卸载的最后一步(CLSID 需手动)

卸载脚本**不会**擅自改写 CLSID 项 —— 因为它指向的"正确原始值"随每个 VirtualBox 构建而异,猜错反而会弄坏 VBox 的 COM 注册。正确做法:

> 设置 → 应用 → 找到 VirtualBox → 修改 → **修复(Repair)**

VBox 自己的安装器会把这个 CLSID 改回 Oracle 原生的 proxy/stub。其余三项(版本号、AR 插件、垫片 DLL)卸载脚本已自动还原。

## 覆盖的安全性

所有覆盖都是**可逆**的:每个被替换的文件,脚本先把原文件备份为 `原文件名.orig.bak`,卸载时(双击 `卸载.bat`)自动从 `.orig.bak` 恢复。

完整性:
1. `payload\VBox52.dll` 和 `payload\VAR_Plugin.dll` 部署前先校验 SHA256,确保整合包未被篡改;
2. 目标位置如果已是相同版本(same hash),直接跳过,不重复覆盖;
3. 覆盖完成后才算成功,不写半截。

## 排错

**双击没反应 / 一闪而过** —— 多半是 UAC 被拒。直接**双击**(不要右键)`安装.bat` 重试,UAC 弹窗点"是"。注意:别用"右键 → 以管理员身份运行"去选*另一个*管理员账户,那会让自动注册被跳过(需再手动点 `注册设备.bat`);正常双击即可,提权由脚本内部处理。

**提示"需要管理员权限"** —— 没经 `安装.bat` 直接跑了 `install.ps1`。请双击 `安装.bat`(它会让 `install.ps1` 提权打补丁、再用登录账户注册)。

**打补丁那步失败、提权窗口一闪而过看不清** —— 日志留在 `%TEMP%\ensp-vbox-shim-install.log`,打开看具体报错。

**"未能自动定位 eNSP 安装目录"** —— 用 `-EnspDir` 手动指定(见上)。

**窗口中文乱码** —— `.bat` 已按 GBK + `chcp 936` 编码,正常不会乱;若仍乱码,通常是把文件用别的编辑器另存改了编码。

**装完 eNSP 仍报版本错误** —— 跑一次 `-Check`,确认注册表 `Version` 是否已是 `5.2.44`、CLSID 是否指向 tools 下的 DLL。

**设备启动很慢(单台 3-5 分钟)** —— 正常现象,不是卡死。本机开了 WSL2/Hyper-V 时,VirtualBox 7.x 用不了 VT-x 硬件加速,只能跑在 Hyper-V 之上,虚拟机启动会明显变慢。点完"开始"耐心等,设备最终会起来。

**设备启动报 error 40 / 起不来** —— 先看安装日志(`%TEMP%\ensp-vbox-shim-install.log`)开头的**环境检测**段,或重跑一次 `-Check`。installer 覆盖的几层成因都在那里:`VBox\x86\` 缺 x86 VCRT(`0x800700C1`)、`vboxserver\` 写权限不足(`VERR_FILE_NOT_FOUND`)、版本伪装未写入。注意:**开着 Hyper-V/WSL/WSA 不是 error-40 的成因**——VBox 7.x 会走 WHP 后端正常运行,只是启动慢(见上一条),不要为此去关 Hyper-V。

**在 Windows Sandbox / WDAG 里报 error 40** —— **不受支持,无法修复**。Windows Sandbox 通过 VSMB 共享挂载系统盘(`\Device\vmsmb\...`),而 VirtualBox 的进程加固要求 `kernel32.dll`/`ntdll.dll` 从普通磁盘卷(`\Device\HarddiskVolume`)加载,二者冲突,VM 进程在启动阶段就被加固终止(加固日志 `VBoxHardening.log` 里是 `rc=-5632` / `rc=-610`)。这是 Windows Sandbox 与 VirtualBox 的固有冲突,**非本垫片可修复**——原版 VBox 在沙箱内同样起不来。请改用普通虚拟机或物理机。

## 已知限制:嵌套虚拟化

在**虚拟机内**运行本套件时(宿主机开 Hyper-V、再在 Win10/Win11 客户机里跑 eNSP——三层嵌套),网络设备可能显示"正在运行"却**不出 `####` 进度条、始终进不到 `<Huawei>` 命令行**。

成因:Win10 客户机向上暴露 VT-x,VBox 据此选了原生 HM(unrestricted guest)后端;嵌套场景下该后端会卡住 VRP 32 位内核实模式→分页的早期引导(客户机内核固定地址 panic)。Win11 客户机因报告"VT-x 不可用"会自动回退到 NEM/WHP 后端,反而正常。

解决(在 Win10 客户机内执行,需管理员):

```powershell
# 1. 启用 Windows 虚拟机监控程序平台(WHP)
Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All
# 2. 重启客户机(让 WHP 运行时上线,必须重启)
# 3. 重启后,强制 VBox 走 NEM 后端
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" setextradata global "VBoxInternal/HM/UseNEMInstead" "1"
```

物理机(非嵌套)不受此限制,无需任何额外配置。

## 系统要求

- Windows(脚本用系统自带 PowerShell 5.1,无需额外装运行时);
- 已安装原版 eNSP 与官方 VirtualBox 7.2.x;
- 管理员权限(`.bat` 会自动申请)。
