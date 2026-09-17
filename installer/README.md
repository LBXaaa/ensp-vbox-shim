# 整合包 · installer/

用途:在原版华为 eNSP 上运行 VirtualBox 7.x。eNSP 与 VirtualBox 的安装位置自动检测,无需手工修改注册表或复制文件。

## 目录内容

| 文件 | 作用 |
|------|------|
| `安装.bat` | 安装入口。部署补丁、注册设备 VM、运行时环境检测 |
| `卸载.bat` | 卸载入口。还原版本字符串与插件文件 |
| `环境检查.bat` | 只读采集本机环境并生成报告。`-Fix` 参数进入修复流程 |
| `注册设备.bat` | 后备入口。仅在自动注册被跳过时使用 |
| `清理残留.bat` | 结束未退出的 VirtualBox 进程 |
| `install_all.ps1` | 编排器,被 `安装.bat` 调用。提权部署补丁,以登录账户身份注册,最后执行运行时检测 |
| `install.ps1` | 补丁部署脚本,被 `install_all.ps1` 与 `卸载.bat` 调用 |
| `register_vms.ps1` | VM 注册脚本,被 `install_all.ps1` 与 `注册设备.bat` 调用 |
| `cleanup_orphans.ps1` | 残留进程清理脚本,被 `清理残留.bat` 调用 |
| `diag.ps1` | 诊断与修复实现,被 `环境检查.bat` 调用。默认只读 |
| `fix.ps1` | 修复原语库,由 `diag.ps1` 引用 |
| `checks.ps1` | 只读探测库,由 `install.ps1` / `diag.ps1` / `fix.ps1` 共用 |
| `payload/VBox52.dll` | COM/vtable 垫片,部署至 eNSP 树的四个加载位置 |
| `payload/VAR_Plugin.dll` | AR 插件补丁(IVirtualBox 5.2 → 7.2 vtable 重映射) |
| `payload/msvcrt-x86/*.dll` | x86 VC++ 运行时,部署至 `VBox\x86\` |

## 使用

### 安装

前置条件:eNSP 与 VirtualBox 7.2.x 均已由各自的官方安装程序安装。本包不包含这两者。

运行 `安装.bat`,UAC 窗口选择"是"。窗口输出三个步骤的结果:

1. 部署垫片、AR 插件补丁与 x86 运行时(需要管理员权限);
2. 注册基础设备 VM(以登录账户身份);
3. 运行时环境检测,并执行检测结果中标记为可修的项。

结束后启动 eNSP,创建设备验证。

整个流程触发两次 UAC:第 1 次用于部署补丁;第 2 次仅在第 3 步检出可修项时触发,无检出时不触发、不修改系统。

第 3 步检出可修项时先列出影响范围再请求确认。无损项直接执行;有损项(执行期间网络中断)逐条确认。

### 环境检查(`环境检查.bat`)

只读采集本机环境事实,生成报告至 `%ProgramData%\ensp-vbox-shim\diag-<时间戳>.txt`。报告可原样附入 issue。

报告内容:系统版本与构建号、四个垫片投放点的哈希、CLSID 指向、host-only 网络六层状态、基础 VM 注册状态与 `<VM>_Link` 快照、最近一次启动的 `VBox.log` 与 `VBoxHardening.log` 尾部。

执行账户必须与启动 eNSP 的账户相同。报告读取该账户的 `%USERPROFILE%\.VirtualBox\`;其他账户下的内容与 eNSP 实际使用的不一致。

采集阶段不启动虚拟机、不修改系统设置。报告不含交互记录。

报告共 10 节,第 [9] 节列出检出项及其对应命令。修复通过以下形式执行:

```bat
环境检查.bat                     :: 只生成报告
环境检查.bat -Fix                :: 执行全部无损项
环境检查.bat -Fix all            :: 含需确认项,逐条确认
环境检查.bat -Fix firewall       :: 仅执行指定项(id 见报告第 [9] 节)
环境检查.bat -Fix all -DryRun    :: 列出计划,不执行
环境检查.bat -Fix all -Yes       :: 跳过逐条确认
```

执行过的命令逐条回显,并写入 `<报告名>.repair.txt`。

需确认项在读取不到输入时(无人值守、输入被重定向)一律不执行。跳过确认需显式指定 `-Yes`。修复需要管理员权限,未提权时脚本给出提示。

第 [9] 节在无检出项的机器上为空,此时不列出条目、不修改设置。

### 注册设备(`注册设备.bat`)

`安装.bat` 默认自动完成注册,正常流程无需单独运行本脚本。

自动注册被跳过的条件:以"其他管理员账户"运行安装。此时进程身份与启动 eNSP 的登录用户不一致,注册写入错误的用户配置,eNSP 无法读取。安装窗口对此给出提示。处理方式:以启动 eNSP 的账户(非管理员)运行 `注册设备.bat`。

脚本扫描 `vboxserver\` 下的基础盘(`AR_Base`、`WLAN_*_Base`),未注册的执行注册,已注册的先注销再注册。操作幂等、可逆;注销不带 `--delete`,不修改磁盘内容。

这些基础设备 VM 是创建设备时的克隆源,未注册时设备无法启动。

仅查看操作内容不执行:

```powershell
powershell -ExecutionPolicy Bypass -File register_vms.ps1 -Check
```

注册阶段不提升权限。VM 注册写入当前用户的 `.VirtualBox\VirtualBox.xml`,该文件必须与启动 eNSP 的账户一致。`install_all.ps1` 按此划分权限:补丁阶段提权,注册阶段使用登录账户身份。

### 需要导入设备包的设备

部分设备需要外挂磁盘镜像,镜像不随安装程序提供。判定依据:插件目录下含 `Database\` 子目录,且其中的模板指向该目录下的镜像文件。全新安装时这些 `Database\` 为空。

| 插件目录 | 设备型号 | 镜像 | VM 模板 |
|---|---|---|---|
| `plugin\ngfw` | USG6000V | `Database\vfw_usg.vdi`(约 940 MB) | `tools\ngfw\vfw_usg_for_vbox5.0.vbox` |
| `plugin\svrp` | CE6800、CE12800 | `Database\CE.img` | `Tools\svrp\CE.xml` |
| `plugin\cx` | CX200 | `Database\CX.img` | `Tools\svrp\CX.xml` |
| `plugin\ne` | NE40E | `Database\NE40E.img` | `Tools\svrp\NE40E.xml` |
| `plugin\ne5ke` | NE5000E | `Database\NE5000E.img` | `Tools\svrp\NE5KE.xml` |
| `plugin\ne9k` | NE9000 | `Database\NE9000.img` | `Tools\svrp\NE9K.xml` |

七台设备对应六个包;CE6800 与 CE12800 共用 `CE.img`(`plugin\svrp` 下只有一份模板)。镜像位于各自插件的 `Database\` 下,文件名与模板中 `location="../../Database/..."` 的值一致,不可改名。

eNSP 的「导入设备包」对话框为通用实现(提示文案为 `请导入%s的设备包`),其内置说明仅以 USG6000V 为例。本包不附带上述任何镜像。

导入方式:在对话框的「包路径」填入镜像文件完整路径,点击「导入」,复制完成后再次点击启动。对话框只接受镜像文件本身,输入为 zip 包时需先解压。

六种设备包(含 `vfw_usg.vdi`)均使用此路径,无需额外脚本。对话框将文件复制到该插件自身的 `Database\` 下,后续注册由 eNSP 与垫片完成:

- **CE / CX / NE40E / NE5000E / NE9000** —— 插件发出 `VBoxManage registervm "<插件>\Tools\svrp\<型号>.xml"`,随后以 `startvm <VM名> --type headless` 原地启动,不克隆、不创建快照。
- **USG6000V** —— 插件使用链接克隆,需要已注册的 `vfw_usg` 与一个 `vfw_usg_Link` 快照。垫片在插件探测该设备时自动完成注册与快照创建,随后 eNSP 执行 `clonevm vfw_usg --snapshot vfw_usg_Link ...`。

`vfw_usg.vdi` 约 940 MB,复制耗时一两分钟,进度条结束后对话框自动关闭。

**资源需求**:上述五台设备直接启动 VM 本身,不克隆。CE / CX / NE40E / NE5000E / NE9000 的模板各分配 4 GB 内存,内存不足时系统换页,可能导致整机无响应(实测在分配 2 GB 的客户机上,一台 CE12800 即可使其失去响应)。模板各分配 1 个 vCPU,嵌套环境下启动明显变慢,NE 系列等大框式设备启动时间可超过十分钟。

权限划分与 `安装.bat` 相同:写入 `Program Files` 的阶段提权,注册阶段使用登录账户身份。

### 设备关闭后的残留进程(CE / CX / NE 系列)

**现象**:关闭这些设备或关闭 eNSP 后,`VBoxHeadless.exe` 不立即退出,每个进程占用 1.2–1.5 GB 内存。设备图标可能显示「异常退出」,或弹出 `VBoxHeadless.exe - 应用程序错误`(`0x...24 该内存不能为 read`)。

**2026-09-12 实测**:

- 关闭 eNSP 时,eNSP 为每台设备发出 `VBoxManage controlvm <VM名> poweroff`(硬断电)。
- 这些设备的客户机为 Linux,硬断电后收尾耗时较长,实测超过五分钟才陆续退出,期间内存不释放。
- 部分进程在收尾时因访问空指针崩溃并弹出「应用程序错误」对话框。该对话框未关闭时进程不释放内存。
- 全部退出后内存正常归还(实测由 18.0 GB 恢复至 24.8 GB),不属于永久泄漏。

**处理**:

1. 出现「应用程序错误」对话框时点击【确定】关闭。
2. 或运行 `清理残留.bat`。清理范围按 eNSP 运行状态区分:
   - eNSP 已关闭:所有 `VBoxHeadless` 均为残留,列出后确认即全部结束;
   - eNSP 运行中:仅结束 VirtualBox 记录中已不在运行的孤儿进程,使用中的设备不受影响。

   脚本先列出待清理进程(含 VM 名与内存占用量),确认后执行。实测强制结束后 VirtualBox 的记账自动恢复,不产生幽灵条目。

> 该问题属于 VirtualBox 7.x 在硬断电收尾时的行为,与本垫片无关:垫片为 32 位,仅加载进 32 位 eNSP 进程,而 `VBoxHeadless.exe` 为 64 位。记录待后续版本处理。

**启动进度条**:上述设备为完整虚拟机(模板各分配 4 GB 内存),同时启动多台时 eNSP 的进度条可能长时间静止。进度条静止不代表设备未启动。可通过双击设备进入控制台确认,或检查 `plugin\<插件>\LogFile\infolog*.txt` 中是否出现 `Received run ok msg`。启动过程中终止 eNSP 会一并终止正在引导的设备。

### 卸载

运行 `卸载.bat`。该脚本还原版本字符串,并从 `.orig.bak` 还原 AR/NGFW 插件与垫片 DLL。

`tools\`、`plugin\ngfw\tools\ngfw\` 两处存在华为原文件备份,还原为原版。eNSP 根目录、`vboxserver\` 两处的垫片为安装时新建,无备份文件,卸载时跳过。

CLSID 项需手动处理,见下方「卸载的最后一步」。

### 只检测不改动

查看当前机器状态,不执行修改:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Check
```

输出内容:eNSP/VBox 路径、垫片 DLL 部署状态、注册表版本值、CLSID 指向、`VAR_Plugin.dll` 与 `NGFW_Plugin.dll` 补丁状态,以及环境快照。

### 环境快照

安装期间与 `-Check` 期间输出一段环境快照,内容为设备启动失败(error 40)的常见成因,只读取不修改:

- **CPU / VT-x** —— 固件虚拟化开关状态、VMX 扩展可用性。启用 Hyper-V/WSL 时固件项通常显示"未启用",此为 hypervisor 接管所致。
- **Hyper-V / WHP / 内存完整性(HVCI)/ 虚拟机平台** —— 任一项启用时,VBox 7.x 使用 WHP 后端运行。eNSP 原配的 VBox 5 与 Hyper-V 冲突,无法启动;7.x 通过 WHP 与 Hyper-V/WSL/WSA 共存,代价是设备启动时间增加(单台 3–5 分钟)。此为后端差异,不是故障,无需关闭 Hyper-V。
- **x86 VCRT** —— `VBox\x86\` 下 `VCRUNTIME140.dll` / `MSVCP140.dll` 的存在性。缺失时产生 `0x800700C1`,进而导致 error 40;安装步骤会补入这两个文件。
- **版本伪装** —— 注册表 `Oracle\VirtualBox\Version` 的当前值。

该快照同时写入安装日志 `%ProgramData%\ensp-vbox-shim\install.log`。

### 手动指定路径

自动检测失败时指定路径:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -EnspDir "D:\Program Files\Huawei\eNSP" -VBoxDir "D:\Program Files\Oracle\VirtualBox"
```

## 安装执行的操作

1. **部署垫片 DLL** —— 将 `payload\VBox52.dll` 写入 eNSP 树的四个加载位置:`tools\`、`vboxserver\`、eNSP 根目录、`plugin\ngfw\tools\ngfw\`。每个位置先比对哈希:一致则跳过;不一致则备份原文件为 `.orig.bak` 后覆盖。
2. **写入版本伪装** —— 将 `HKLM\SOFTWARE\Oracle\VirtualBox` 的 `Version` 值改为 `5.2.44`(64 位视图与 WOW6432Node 视图均写入)。eNSP 启动时读取该值,检测到 7.x 时拒绝运行。
3. **重定向 CLSID InprocServer32** —— 将 `CLSID\{B1A7A4F2-...}\InprocServer32` 的默认值指向 `tools\VBox52.dll` 的实际路径。路径按 eNSP 安装位置生成。
4. **覆盖 AR 插件** —— 以 `payload\VAR_Plugin.dll`(预构建补丁版)覆盖 `plugin\ar1000v\VAR_Plugin.dll`,原文件备份为 `.orig.bak`。不在运行时执行字节补丁。
5. **部署 x86 VC++ 运行时** —— 将 `VCRUNTIME140.dll` / `MSVCP140.dll` 写入 VirtualBox 的 `x86\` 子目录。
6. **授予权限** —— 为登录用户授予 `vboxserver\` 的运行时写权限。

详细原理见仓库 `docs/architecture.md`。

> `NGFW_Plugin.dll` 不包含在上述六步内。2026-09-10 的 A/B 实测显示,出厂原版与 22 站点 vtable 补丁版的启动结果无差异(失败签名相差小于 1 毫秒),出厂原版可正常启动 USG6000V。补丁器保留在 `patches/` 下,安装器不修改该文件。`-Check` 仍报告其当前状态(出厂原版 / 已打补丁)。

## 自动检测逻辑

**eNSP 目录** —— 读取卸载注册表中 DisplayName 含 `eNSP` 的项的 `InstallLocation`;未找到时回退至 `Program Files (x86)\Huawei\eNSP` 与 `Program Files\Huawei\eNSP`。两种来源均校验目录下存在 `tools\` 子目录。

**VirtualBox 目录** —— 读取 `HKLM\SOFTWARE\Oracle\VirtualBox` 的 `InstallDir`(32 位与 64 位视图均尝试);未找到时使用默认安装路径。

任一项检测失败时使用 `-EnspDir` / `-VBoxDir` 指定。

## 卸载的最后一步(CLSID)

卸载脚本不修改 CLSID 项。该项的正确原始值随 VirtualBox 构建版本变化,推测值可能破坏 VBox 的 COM 注册。恢复方式:

> 设置 → 应用 → VirtualBox → 修改 → **修复(Repair)**

VirtualBox 安装器将该 CLSID 恢复为 Oracle 原生的 proxy/stub。其余三项(版本号、AR 插件、垫片 DLL)由卸载脚本自动还原。

## 覆盖的可逆性

所有覆盖均可逆。被替换的文件先备份为 `原文件名.orig.bak`,卸载时由 `卸载.bat` 从 `.orig.bak` 恢复。

完整性保证:

1. `payload\VBox52.dll` 与 `payload\VAR_Plugin.dll` 部署前校验 SHA256;
2. 目标位置哈希一致时跳过覆盖;
3. 覆盖完成后才记录成功状态。

## 排错

> 安装后设备无法启动时,先运行 `环境检查.bat` 生成报告。该报告按分层给出结论,优先于本节逐条比对。

**运行无反应 / 窗口一闪而过** —— UAC 被拒。双击(不使用右键菜单)`安装.bat` 重试,UAC 窗口选择"是"。使用"右键 → 以管理员身份运行"并选择其他管理员账户会跳过自动注册,需另行运行 `注册设备.bat`。

**提示"需要管理员权限"** —— 未经 `安装.bat` 直接运行了 `install.ps1`。运行 `安装.bat`。

**补丁阶段失败、提权窗口一闪而过** —— 日志位于 `%ProgramData%\ensp-vbox-shim\install.log`。

**"未能自动定位 eNSP 安装目录"** —— 使用 `-EnspDir` 指定。

**窗口中文乱码** —— `.bat` 按 GBK + `chcp 936` 编码。出现乱码通常表示文件被其他编辑器另存修改了编码。

**安装后 eNSP 仍报版本错误** —— 运行 `-Check`,确认注册表 `Version` 为 `5.2.44`、CLSID 指向 `tools` 下的 DLL。

**设备启动耗时 3–5 分钟** —— 后端差异,非卡死。本机启用 WSL2/Hyper-V 时,VirtualBox 7.x 无法使用 VT-x 硬件加速,运行在 Hyper-V 之上,启动时间增加。

**设备启动报 error 40** —— 查看安装日志开头的环境快照段,或重新运行 `-Check`。installer 覆盖的成因包括:`VBox\x86\` 缺少 x86 VCRT(`0x800700C1`)、`vboxserver\` 写权限不足(`VERR_FILE_NOT_FOUND`)、版本伪装未写入。启用 Hyper-V/WSL/WSA 不在 error-40 的成因内:VBox 7.x 通过 WHP 后端运行,代价仅为启动速度。

**升级 VirtualBox 后报 error 40,且垫片日志无异常记录** —— 检查 VirtualBox 的 host-only 网络。该组件有两类独立故障,现象相近,处理方式不通用(D1 的处理方式对 D2 无效)。

**D1:host-only 过滤驱动绑定失效(适配器存在)** —— 检查 eNSP 的命令日志 `eNSP\vboxserver\log\VBoxManage.log`,出现以下内容即为 D1:

```
Failed to open/create the internal network
'HostInterfaceNetworking-VirtualBox Host-Only Ethernet Adapter' (VERR_INTNET_FLT_IF_NOT_FOUND)
Failed to attach the network LUN (VERR_INTNET_FLT_IF_NOT_FOUND)
```

此时网络连接中存在 VirtualBox Host-Only Ethernet Adapter(状态 Up),`VBoxDrvInst.exe list` 可列出 `VBoxNetAdp6` / `VBoxNetLwf`,但绑定失效。垫片与此无关:其 `findMachine` / `clonevm` / `modifyvm` 均成功,失败发生在随后的 `startvm`,VBox 因无法创建 host-only 网络而拒绝启动。

处理:

1. 控制面板 → 网络连接 → 右键 VirtualBox Host-Only Ethernet Adapter → 禁用,等待数秒 → 启用;
2. 任务管理器中结束 `VBoxSVC.exe` 与 `VBoxSDS.exe`(自动重启),然后完全关闭并重新启动 eNSP。

无效时确认适配器属性中 VirtualBox NDIS6 Bridged Networking Driver 为勾选状态。

**D2:host-only 网络驱动包未注册(适配器不存在)** —— 网络连接中不存在 VirtualBox Host-Only Ethernet Adapter;`VBoxDrvInst.exe list` 不列出任何 VBox 驱动包;`VBoxManage hostonlyif create` 报:

```
Could not find Host Interface Networking driver! Please reinstall
```

D1 的"禁用→启用"处理方式对 D2 无效(无适配器可禁用,无绑定可刷新),必须先安装驱动包。顺序为硬依赖:

```
VBoxDrvInst.exe install --inf-file "<VBoxDir>\drivers\network\netadp6\VBoxNetAdp6.inf"
netcfg.exe -v -l "<VBoxDir>\drivers\network\netlwf\VBoxNetLwf.inf" -c s -i oracle_VBoxNetLwf
```

第 2 条只能使用 `netcfg.exe`:对 NDIS 过滤驱动,`VBoxDrvInst install` 仅将驱动包预装进驱动库,不创建 NetService 组件。两条均安装完毕后禁用并启用适配器一次,然后执行 `VBoxManage hostonlyif create`,配合 `ipconfig` 配置地址并重建 dhcpserver。

> **不报错的失败模式**:仅安装第 1 条(`netadp6`)而未安装第 2 条(`netlwf`)时,`hostonlyif create` 成功,但适配器被创建为 `VirtualBox Host-Only Ethernet Adapter #2`。eNSP 的设备模板按精确名称绑定,无法识别带 `#2` 后缀的名称,现象与"驱动未安装"相同。

报错消失顺序可作为进度判据:`hostonlyif create` 的 `Could not find Host Interface Networking driver!` 与 VBoxSVC 日志的 `HostWrap: ... could not be found` 在安装 `netadp6` 后消失;`VERR_INTNET_FLT_IF_NOT_FOUND` 在安装 `netlwf` 后消失。

**预防** —— 升级或重装 VirtualBox 后,先创建一台含 host-only 网卡的虚拟机并启动,验证网络栈,然后启动 eNSP。安装包不完整(手工解包、绿色部署)是 D2 的常见来源。完整诊断记录见 [`docs/troubleshooting-error40.md`](../docs/troubleshooting-error40.md) 根因 D1 / D2。

**设备启动报 error 40,且绕开 eNSP 直接 `VBoxManage startvm` 同样失败** —— 加固层无法创建 VM 子进程。`VBoxHardening.log` 末尾是 `Error -104 in supR3HardenedWinReSpawn! (enmWhat=5)`,日志里没有被拒的模块,诊断报告里「被拒的模块」也为空。

判别三条:绕开 eNSP 直接启动也失败;加固日志的锚点是 `-104` 而非 `-5657`;报告里没有被拒模块。`-5657` 是加固拒绝了一个具体文件,有卸载对象;`-104` 是 `CreateProcessW` 本身没成功,失败在任何模块被加载之前,没有可卸载的对象。

该问题在 2026-08 更新之后出现、2026-09 累积更新之后消失 —— 停在该区间 build 上的机器装上最新累积更新即可,与 eNSP、与本垫片都无关。完整诊断记录见仓库 [`docs/troubleshooting-error40.md`](../docs/troubleshooting-error40.md) 根因 E。

**Windows Sandbox / WDAG 中报 error 40** —— 不支持,无法修复。Windows Sandbox 通过 VSMB 挂载系统盘(`\Device\vmsmb\...`),而 VirtualBox 的进程加固要求 `kernel32.dll` / `ntdll.dll` 从普通磁盘卷(`\Device\HarddiskVolume`)加载,两者冲突,VM 进程在启动阶段被加固终止(`VBoxHardening.log` 记录 `rc=-5632` / `rc=-610`)。该冲突为 Windows Sandbox 与 VirtualBox 的固有冲突,与本垫片无关;原版 VBox 在沙箱内同样无法启动。改用普通虚拟机或物理机。

## 已知限制:嵌套虚拟化

在虚拟机内运行本套件时(宿主机启用 Hyper-V,在 Win10/Win11 客户机内运行 eNSP,共三层嵌套),网络设备可能显示"正在运行"但不输出 `####` 进度条,无法进入 `<Huawei>` 命令行。

成因:客户机内 VBox 在获得裸 VT-x 时选择原生 HM(unrestricted guest)后端;二级嵌套下该后端运行 VRP 32 位内核的实模式→分页早期引导存在缺陷,客户机内核在固定地址 panic(`c013e501`)。决定因素是 VT-x 的归属与后端选择。客户机 OS 决定默认行为:Win10 客户机默认暴露 VT-x,选择原生 HM,崩溃;Win11 客户机报告 VT-x 不可用,回退 NEM,正常。该问题仅在 Win10 客户机上出现。

处理方式(在客户机内执行,需管理员):

```powershell
# 启用 Windows 虚拟机监控程序平台(WHP),使 VBox 无法获得裸 VT-x,回退至 NEM
Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All
# 重启客户机
```

WHP 是全局后端选择,重启后新克隆的设备自动使用 NEM,无需逐台设置 `UseNEMInstead`。仅当 VT-x 对 VBox 仍可见时,才需要补充:

```powershell
VBoxManage setextradata <vm> "VBoxInternal/HM/UseNEMInstead" "1"
```

判定与验证细节见 [docs/troubleshooting-error40.md 根因 C](../docs/troubleshooting-error40.md)。

物理机(非嵌套)不受此限制。

## 系统要求

- Windows,使用系统自带 PowerShell 5.1;
- 已安装原版 eNSP 与官方 VirtualBox 7.2.x;
- 管理员权限(`.bat` 自动申请)。
