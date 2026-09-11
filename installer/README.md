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
| `清理残留.bat` | **兜底**:关闭 eNSP 后收掉没退干净的 VirtualBox 进程。见下方"关闭设备后的残留进程" |
| `cleanup_orphans.ps1` | 清理脚本(被 `清理残留.bat` 调用)。只结束孤儿进程,不碰正在运行的 VM |
| `payload/VBox52.dll` | 预编译好的 COM/vtable 垫片,安装时拷进 eNSP\tools\ |

## 怎么用

### 安装

1. 先装好**原版** eNSP 和**官方** VirtualBox 7.2.x(本仓库不附带它们)。
2. 双击 **`安装.bat`**。
3. 弹出 UAC 窗口点"是"(打补丁要写注册表 + 改 Program Files,需要管理员权限)。
4. 看窗口里的两步:第 1 步部署垫片、AR 补丁和运行时,第 2 步自动注册基础设备 VM。结束后启动 eNSP 拉一台设备试试。

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
### 需要另行导入设备包的设备

eNSP 有一批设备要外挂磁盘镜像,镜像不随安装程序提供。判断依据是各插件的目录:
凡带 `Database\` 子目录、且其中的模板指向该目录下某个镜像的,就是这一类。全新安装时
这些 `Database\` 全是空的。

| 插件目录 | 设备面板上的型号 | 需要的镜像 | 对应的 VM 模板 |
|---|---|---|---|
| `plugin\ngfw` | USG6000V | `Database\vfw_usg.vdi`(约 940 MB) | `tools\ngfw\vfw_usg_for_vbox5.0.vbox` |
| `plugin\svrp` | **CE6800、CE12800** | `Database\CE.img` | `Tools\svrp\CE.xml` |
| `plugin\cx` | CX200 | `Database\CX.img` | `Tools\svrp\CX.xml` |
| `plugin\ne` | NE40E | `Database\NE40E.img` | `Tools\svrp\NE40E.xml` |
| `plugin\ne5ke` | NE5000E | `Database\NE5000E.img` | `Tools\svrp\NE5KE.xml` |
| `plugin\ne9k` | NE9000 | `Database\NE9000.img` | `Tools\svrp\NE9K.xml` |

七台设备、六个包 —— CE6800 与 CE12800 共用 `CE.img`(`plugin\svrp` 下只有这一份模板)。
镜像一律落在各自插件的 `Database\` 下,文件名与模板里 `location="../../Database/..."`
写死的一致,改名会认不出。

eNSP 界面上的「导入设备包」对话框是**通用**的(提示文案是 `请导入%s的设备包`),但它给
的说明只举了 USG6000V 为例。整合包**不附带**上述任何镜像。

启动一台缺镜像的设备时,eNSP 会弹出这个对话框:标题「导入设备包」,正文
`说明:请导入<型号>的设备包。`,带「包路径」输入框和「浏览…/导入/取消」。2026-09-11
在全新 Win10 上实测(以缺 `CE.img` 的 CE12800 为例),对话框正常弹出、eNSP 不卡死。
**同一场景在旧版垫片下是另一副样子**:VBox 服务进程直接退出,界面上没有任何提示,
只看到进度条不走 —— 这处差别是垫片修掉的,不是 eNSP 的问题。

**导入方式:直接用 eNSP 自带的「导入设备包」对话框。** 启动缺镜像的设备时会弹出它,
在"包路径"里填上镜像文件的完整路径,点「导入」,等拷贝完成后再点一次启动即可。

**六种设备包(含 `vfw_usg.vdi`)都支持这条路径,无需任何额外脚本。** 对话框只做一件事:
把文件复制到该插件自己的 `Database\`。后续的注册由 eNSP 与垫片自动完成:

- **CE / CX / NE40E / NE5000E / NE9000**:插件自己发
  `VBoxManage registervm "<插件>\Tools\svrp\<型号>.xml"`,然后 `startvm <VM名> --type headless`
  原地启动这台 VM(不克隆、不要快照)。
- **USG6000V**:插件走**链接克隆**,需要一台已注册的 `vfw_usg` 加一个 `vfw_usg_Link`
  快照。垫片在插件探测该设备时**自动补上这两步**(注册 + 建快照),之后 eNSP 照常
  `clonevm vfw_usg --snapshot vfw_usg_Link ...`。用户不需要做任何额外操作。

> 若拿到的是 **zip 包**,需先自行解压出里面的镜像文件再选择 —— 对话框只接受镜像本身,
> 不认 zip。

`vfw_usg.vdi` 约 940 MB,拷贝要一两分钟,进度条走完对话框会自行关闭。

> **这五台是完整虚拟机,先确认内存够。** eNSP 是**直接启动这台 VM 本身**(不克隆),
> 所以开一台就等于开一台完整虚拟机:模板里 CE / CX / NE40E / NE5000E / NE9000
> 各要 **4 GB** 内存。内存不够时会一路换页抖动到整机失去响应 —— 实测在一台只给了
> 2 GB 的客户机上,一台 CE12800 就能把它拖死。开之前先看内存,一次别拉太多台。
> (另外这些模板只给 1 个 vCPU,嵌套环境里启动会明显偏慢,NE 这类大框式设备等上十几
> 分钟属正常。)

与 `安装.bat` 一样分两段权限:写 `Program Files` 那段提权,注册那段退回登录账户身份
(注册写入当前用户的 `.VirtualBox\VirtualBox.xml`,必须与启动 eNSP 的账户一致)。


### 关闭设备后的残留进程(CE / CX / NE 系列)

**现象**:关闭这几台(以及关掉整个 eNSP)之后,VirtualBox 的后台进程
`VBoxHeadless.exe` 不会立刻消失,每台仍占 **1.2–1.5 GB** 内存。设备图标可能显示
**「异常退出」**,甚至弹出 `VBoxHeadless.exe - 应用程序错误`(`0x...24 该内存不能为 read`)。

**2026-09-12 实测结论**:

- 关闭 eNSP 时,它会为每台设备补发 `VBoxManage controlvm <VM名> poweroff`(硬断电)。
- 这几台的客户机是 **Linux 系统**,硬断电后的收尾**很慢** —— 实测要 **5 分钟以上**
  才陆续退完;期间内存一直不释放,看起来就像"关不掉"。
- 其中个别进程会在收尾时**崩溃**(访问空指针),弹出「应用程序错误」框;
  **不点掉那个框,它就一直挂着不放内存。**
- **全部退完后内存会正常归还**(实测从 18.0 GB 回到 24.8 GB),不是永久泄漏。

**处理办法**:

1. 弹出「应用程序错误」框时**点【确定】**把它关掉,进程才会结束;
2. 不想等的话,双击 **`清理残留.bat`**,它会立刻找出并结束这些残留进程。
   该脚本**只结束"VirtualBox 账本上已不在运行"的孤儿进程**,正在正常运行的虚拟机
   会被跳过,可以放心用。

> 这是 VirtualBox 7.x 自身在硬断电收尾时的问题,与垫片无关 —— 垫片是 32 位、
> 只加载进 32 位的 eNSP 进程,而 `VBoxHeadless.exe` 是 64 位,两者不在同一个进程里。
> 已记录,留待后续版本处理。

**顺带一提**:这几台是**完整虚拟机**(模板各配 4 GB 内存),同时拉多台时 eNSP 的启动
进度条可能长时间不动甚至看起来卡死 —— **这不代表设备没起来**。可以双击设备试进控制台,
或看 `plugin\<插件>\LogFile\infolog*.txt` 里有没有 `Received run ok msg`。
**别因为进度条不动就强杀 eNSP**,那会把正在引导的设备一并杀掉。

### 卸载还原

双击 **`卸载.bat`**,会还原版本字符串、从 `.orig.bak` 还原 AR/NGFW 插件与垫片 DLL。其中 `tools\`、`plugin\ngfw\tools\ngfw\` 两处有华为原文件的备份,会被还原回原版;eNSP 根目录、`vboxserver\` 两处的垫片是安装时新建的、无原文件备份,卸载时直接跳过(属正常)。CLSID 项需要手动跑一次 VBox 修复(见下方"卸载的最后一步")。

### 只检测不改动

想先看看当前机器是什么状态,不做任何改动:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Check
```

会打印 eNSP/VBox 路径、垫片 DLL 是否就位、注册表版本号、CLSID 指向、VAR_Plugin.dll 和 NGFW_Plugin.dll 的补丁状态，并附一段**环境检测**（见下）。

### 环境检测（排查用，只读不改动）

安装时（以及 `-Check` 时）会自动打印一段环境快照，聚焦设备启动失败（error 40）的几类常见成因，**只读取、不改动系统**：

- **CPU / VT-x** —— 固件虚拟化是否开启、VMX 扩展是否可用（开了 Hyper-V/WSL 时固件项常报"未启用"，这是 hypervisor 接管所致，属正常）；
- **Hyper-V / WHP / 内存完整性(HVCI) / 虚拟机平台** —— 任一启用，VBox 7.x 会走 WHP 后端运行（eNSP 原配的 VBox 5 与 Hyper-V 冲突起不来，7.x 靠 WHP 才能与 Hyper-V/WSL/WSA 共存）。代价只是设备启动变慢（单台 3-5 分钟），**不是故障，无需关闭 Hyper-V**；
- **x86 VCRT** —— `VBox\x86\` 下的 `VCRUNTIME140.dll` / `MSVCP140.dll` 是否就位（缺它 → `0x800700C1` → error 40，安装步骤会补上）；
- **版本伪装** —— 注册表 `Oracle\VirtualBox\Version` 当前值。

这段同时显示在窗口里、也写进安装日志（`%ProgramData%\ensp-vbox-shim\install.log`），设备无法启动时先看它。

### 自动检测失败时手动指定路径

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -EnspDir "D:\Program Files\Huawei\eNSP" -VBoxDir "D:\Program Files\Oracle\VirtualBox"
```

## 它到底改了什么(安装的 6 步)

1. **部署垫片 DLL** —— 把 `payload\VBox52.dll` 覆盖到 eNSP 树内**全部 4 个加载位置**:`tools\`、`vboxserver\`、eNSP 根目录、`plugin\ngfw\tools\ngfw\`。每个位置先查 hash:已经是同一版本就跳过,否则备份原文件为 `.orig.bak` 后覆盖。

2. **写版本伪装** —— 注册表 `HKLM\SOFTWARE\Oracle\VirtualBox` 的 `Version` 改成 `5.2.44`(64 位 + 32 位 WOW6432Node 两个视图都写)。eNSP 启动时检查这个值,装的是 7.x 它会拒跑。

3. **劫持 CLSID InprocServer32** —— 把 `CLSID\{B1A7A4F2-...}\InprocServer32` 的默认值指向 `tools\VBox52.dll` 的实际路径。路径随 eNSP 安装位置动态生成。

4. **覆盖 AR 插件** —— 用 `payload\VAR_Plugin.dll`(预构建的已补丁版)直接覆盖 `plugin\ar1000v\VAR_Plugin.dll`,备份原文件为 `.orig.bak`。不再运行时打字节补丁。

5. **部署 x86 VC++ 运行时** —— 把 `VCRUNTIME140.dll` / `MSVCP140.dll` 放进 VirtualBox 的 `x86\` 子目录。

6. **授权 vboxserver\** —— 给登录用户授予运行期写权限。

六步详细原理见仓库 `docs/architecture.md`。

> **`NGFW_Plugin.dll` 不在这六步里。** 2026-09-10 的受控 A/B 实测显示,出厂原版与
> 22 站点 vtable 补丁版在启动结果上没有任何差异(失败签名相差不到 1 毫秒),且出厂
> 原版即可正常启动 USG6000V。补丁器仍留在 `patches/` 下备查,安装器不碰该文件。
> `-Check` 仍会报告它的当前状态(出厂原版 / 被手工打过补丁),仅供排查。

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

**打补丁那步失败、提权窗口一闪而过看不清** —— 日志留在 `%ProgramData%\ensp-vbox-shim\install.log`,打开看具体报错。

**"未能自动定位 eNSP 安装目录"** —— 用 `-EnspDir` 手动指定(见上)。

**窗口中文乱码** —— `.bat` 已按 GBK + `chcp 936` 编码,正常不会乱;若仍乱码,通常是把文件用别的编辑器另存改了编码。

**装完 eNSP 仍报版本错误** —— 跑一次 `-Check`,确认注册表 `Version` 是否已是 `5.2.44`、CLSID 是否指向 tools 下的 DLL。

**设备启动很慢(单台 3-5 分钟)** —— 正常现象,不是卡死。本机开了 WSL2/Hyper-V 时,VirtualBox 7.x 用不了 VT-x 硬件加速,只能跑在 Hyper-V 之上,虚拟机启动会明显变慢。点完"开始"耐心等,设备最终会起来。

**设备启动报 error 40 / 起不来** —— 先看安装日志(`%ProgramData%\ensp-vbox-shim\install.log`)开头的**环境检测**段,或重跑一次 `-Check`。installer 覆盖的几层成因都在那里:`VBox\x86\` 缺 x86 VCRT(`0x800700C1`)、`vboxserver\` 写权限不足(`VERR_FILE_NOT_FOUND`)、版本伪装未写入。注意:**开着 Hyper-V/WSL/WSA 不是 error-40 的成因**——VBox 7.x 会走 WHP 后端正常运行,只是启动慢(见上一条),不要为此去关 Hyper-V。

**在 Windows Sandbox / WDAG 里报 error 40** —— **不受支持,无法修复**。Windows Sandbox 通过 VSMB 共享挂载系统盘(`\Device\vmsmb\...`),而 VirtualBox 的进程加固要求 `kernel32.dll`/`ntdll.dll` 从普通磁盘卷(`\Device\HarddiskVolume`)加载,二者冲突,VM 进程在启动阶段就被加固终止(加固日志 `VBoxHardening.log` 里是 `rc=-5632` / `rc=-610`)。这是 Windows Sandbox 与 VirtualBox 的固有冲突,**非本垫片可修复**——原版 VBox 在沙箱内同样起不来。请改用普通虚拟机或物理机。

## 已知限制:嵌套虚拟化

在**虚拟机内**运行本套件时(宿主机开 Hyper-V、再在 Win10/Win11 客户机里跑 eNSP——三层嵌套),网络设备可能显示"正在运行"却**不出 `####` 进度条、始终进不到 `<Huawei>` 命令行**。

成因:客户机内 VBox 若拿到裸 VT-x,会选原生 HM(unrestricted guest)后端;二级嵌套下
该后端跑 VRP 32 位内核的实模式→分页早期引导有缺陷,客户机内核固定地址 panic(`c013e501`)。
深层变量是**谁拿到裸 VT-x、走哪个后端**;而客户机 OS 默认决定走哪个:**Win10 客户机**默认
暴露 VT-x → 走原生 HM → 崩,**Win11 客户机**报告 VT-x 不可用 → 自动回退 NEM → 正常。
所以这问题实际只在 **Win10 客户机**上出现,Win11 客户机一般天然规避。

解决(在客户机内执行,需管理员):

```powershell
# 启用 Windows 虚拟机监控程序平台(WHP),夺走 VBox 的裸 VT-x、逼它走 NEM
Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All
# 重启客户机(让 WHP 运行时上线,必须重启)
```

WHP 是**全局后端选择**,重启后每台新克隆自动走 NEM,**无需**逐台设 `UseNEMInstead`。
仅当 VT-x 对 VBox 仍可见(没被 WHP 强制接管)时,才需要补一句
`VBoxManage setextradata <vm> "VBoxInternal/HM/UseNEMInstead" "1"`。
判定与验证细节见 [docs/troubleshooting-error40.md 根因 C](../docs/troubleshooting-error40.md)。

物理机(非嵌套)不受此限制,无需任何额外配置。

## 系统要求

- Windows(脚本用系统自带 PowerShell 5.1,无需额外装运行时);
- 已安装原版 eNSP 与官方 VirtualBox 7.2.x;
- 管理员权限(`.bat` 会自动申请)。
