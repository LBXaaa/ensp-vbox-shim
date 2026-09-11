# 原厂 VBox 5.2 黄金流程观测记录

2026-09-11 夜,在一台全新 Win10 19045 客户机上安装**原厂 eNSP SPC100 + 原厂 VirtualBox
5.2.22**(未打任何垫片、未打任何插件补丁),完整复刻用户描述的导入流程并全程留证。
目的是回答一个当时悬而未决的问题:**`vfw_usg` 到底是谁注册的**。

原始日志存于 `analysis/golden52/`。

## 一、复刻的操作序列

用户描述的原厂流程:

> 拖入设备 → 点击启动 → 弹出导入框 → 选择设备包 → eNSP 拷贝 → 弹窗消失 → 再次点击启动 → 正常启动

实测按此序列逐步执行,每一步都留下证据。**结论是该描述完全准确**,流程一次通过。

## 二、环境

| 项 | 值 |
|---|---|
| 客户机 | Windows 10 19045,Hyper-V 嵌套,已开 `ExposeVirtualizationExtensions` |
| VirtualBox | 5.2.22r126460(原厂) |
| eNSP | V100R003C00SPC100,装在 `C:\Program Files\Huawei\eNSP` |
| 出厂态哈希 | `VAR_Plugin.dll` = `5AE6817A…`(AR 补丁**未**打);`NGFW_Plugin.dll` 原厂 |
| 注册表 | `Version` = `VersionExt` = `5.2.22` |
| `plugin\ngfw\Database\` | 初始为空 |
| 已注册 VM | `AR_Base` + 4×`WLAN_*_Base`(**eNSP 安装时自己注册的**),`vfw_usg` 不在其中 |

VBox 报告 `Processor supports HW virtualization: yes`,Host-Only 适配器已创建。

## 三、观测仪器

四路只读仪器,外加一路改造式仪器:

| 仪器 | 手段 | 观察对象 |
|---|---|---|
| 1 | WMI `__InstanceCreationEvent` on `Win32_Process` | 进程创建 + 父子 PID |
| 2 | 轮询 `%USERPROFILE%\.VirtualBox\VirtualBox.xml` | VM 注册表的每一次变更 |
| 3 | 读 `VirtualBox.xml` 解析 MachineEntry | 注册表内容快照(不 spawn 进程,避免污染仪器 1) |
| 4 | 增量 tail eNSP 目录下所有 `*.log` | eNSP 自身日志,含 `install.log` / `VBoxManage.log` |
| 5 | **包装 `VBoxManage.exe`** | **每一条 VBoxManage 命令行 + 退出码** |

### 3.1 为什么必须包装 VBoxManage.exe

WMI 的 `Win32_Process.CommandLine` 对**短命进程返回空串**——而每一次 VBoxManage 调用都是短命的。
实测中仪器 1 抓到的事件长这样:

```
23:19:06.751 pid=3552 ppid=6564 VBoxManage.exe
            CMD:                       ← 空的
```

**这条仪器在最关键的地方是瞎的。** 因此把 `VBoxManage.exe` 改名为 `VBoxManage_real.exe`,
在原位置放一个 C# 包装器:记录 `Environment.CommandLine` 原文 → 以**原样命令行文本**转发给真身
→ 透传退出码。eNSP 调用的是不带 `.exe` 后缀的 `VBoxManage`,由 CreateProcess 补全,因此照样命中包装器。

包装器的一处坑:子进程的 stdout/stderr 必须**显式重定向后再转发**,不能依赖句柄继承。
父进程的标准句柄来自 PowerShell 管道时不一定可继承,继承式写法下真身的输出会全部丢失——
而 eNSP 要解析 VBoxManage 的输出,静默即等于破坏实验。

### 3.2 一处差点误判的地方

仪器 1 与仪器 5 都会记录 VBoxManage,但**仪器 1 会漏事件**。实测 `snapshot take` 在仪器 1 里
完全没出现,仪器 5 里有。交叉验证时以仪器 5 为准。

## 四、黄金命令序列

点击第二次「启动」后,`vboxmanage_cmds.log` 记录的完整序列:

```
23:35:10.667  list vms
23:35:37.988  snapshot "vfw_usg" delete "vfw_usg_Link"
23:35:38.175  snapshot "vfw_usg" take   "vfw_usg_Link"
23:35:38.347  clonevm vfw_usg --snapshot vfw_usg_Link --options link \
                --name "vfw_usg_Clone_<GUID>" --basefolder "<...>" --register
23:35:38.472  modifyvm <clone> --uart1 off
23:35:38.597  modifyvm <clone> --uartmode2 server \\.\pipe\<GUID>
23:35:38.706  startvm   <clone> --type headless
```

进程树:上述每一条的父进程都是 `eNSP_VBoxServer.exe`(其父为 `eNSP_Client.exe`)。
`VBoxHeadless.exe` 由 `VBoxSVC.exe` 拉起,设备随即进入通信:

```
23:35:41 CAgentStaticCfgProcess::CfgService - read pipe.ReqType = 0
23:35:46 CAgentStaticCfgProcess::CfgService - read pipe.ReqType = 218776920
...
```

结束时状态:

```
"vfw_usg"                                      {12ec8fd1-0e36-4be0-b620-598a8da036eb}
"vfw_usg_Clone_8AD60209-FA1B-4f31-AFC3-16CC04F9CB32"  {a22204ba-...}
vfw_usg 快照: vfw_usg_Link (UUID e9efe421-...)
克隆机 VMState = "running"
```

## 五、核心结论:`vfw_usg` 的注册不走命令行

**整条链路里没有出现过 `registervm`。**

这不是日志缺失——仪器 5 是包在 `VBoxManage.exe` 上的,任何形式的调用都必经此处;
仪器 1(WMI)独立佐证,同样一条都没有。

而 `snapshot "vfw_usg" delete "vfw_usg_Link"` 是在 `23:35:37.988` **成功执行**的,
这要求 `vfw_usg` 在此刻**已经注册**(上一刻 `list vms` 里还没有它)。

**⇒ 注册发生在 `23:35:10` 与 `23:35:37` 之间,经由 COM 接口而非命令行。**

这条结论把排查范围收窄到一处:**`eNSP_VBoxServer.exe` 经 `GetVBoxInstance()` 拿到的那个
对象,调用其 vtable 上的某个方法完成注册。** 而这正是垫片代理所在的位置。

### 5.1 注册时刻的精确测定

"是不是安装时就注册了"是一个值得单独排除的假设。仪器 3 每 2 秒轮询 `VirtualBox.xml`,
内容变化才落盘,因此它的时间戳可以直接定案。全程只有四次记录:

```
23:18:56   AR_Base + 4×WLAN              ← 装完 eNSP 的初始态
23:20:54   (无变化)
23:35:38   + vfw_usg                     ← 出现在这里
23:35:40   + vfw_usg_Clone_8AD60209-…
```

`23:20:54` 到 `23:35:38` 之间注册表**一次都没变过**,而第一次点「启动」发生在 `23:32:44`。

**⇒ 安装时没有注册,第一次点「启动」也没有注册。**

`vfw_usg` 落盘于 `23:35:38`,而 `snapshot "vfw_usg" delete "vfw_usg_Link"` 的时间戳是
`23:35:37.988` —— **同一瞬间,注册就在这条命令之前几毫秒。**

**⇒ 注册由插件在第二次「启动」的链路内部经 COM 完成,紧接着才 shell 出 snapshot 命令。**

第二次点「启动」时 `vfw_usg` **尚未注册**,链路也没有走"删除旧设备"的分支(对比第一次
点击时出现的 `unregistervm --delete`,第二次完全没有)——说明设备包导入后 eNSP 走的
是**全新安装设备**的路径,该路径包含"注册"这一步。

## 六、顺带确证的三件事

### 6.1 空名 `unregistervm` 是 eNSP 自身缺陷

第一次点击「启动」时,原厂 5.2 上同样出现:

```
23:32:44.695  unregistervm  --delete        ← 双空格,VM 名为空
```

VBoxManage 回 `Syntax error: VM name required`。

**该缺陷在原厂环境下原样存在,与垫片无关。** 此前子代理对 `FUN_1000c260` 的反编译结论
(`GetNilString()` 恒返回空串)由此获得实测印证。

### 6.2 导入框只做文件拷贝

导入期间仪器 5 与仪器 1 **均无任何新增命令**,`VirtualBox.xml` 无变更,
`vfw_usg` 仍处未注册态。导入框的全部动作就是把用户选的镜像复制到
`plugin\ngfw\Database\`。

**该对话框接受裸 `.vdi`**(不必是官方 zip):填入 `C:\packages\vfw_usg.vdi` 后点「导入」,
出现「正在拷贝…」进度条,随后对话框自行关闭,无报错。

### 6.3 插件在原厂环境下同样只走了一行日志

第一次点击「启动」时,插件日志 `plugin\ngfw\LogFile\infolog0.txt` 全文只有:

```
2026.09.11 23:32:44 [DEBUG]Init Instance.
```

即插件 `Init()` 执行后链路即中止,随后导入框弹出。**这与垫片环境下的表现一致**——
说明"缺设备包时链路中止并弹导入框"是设计行为,不是故障。

同时 `plugin\ngfw\tools\ngfw\` 下出现了 `vfw_usg.vbox`(7186 字节,内容与
`vfw_usg_for_vbox5.0.vbox` 模板一致),说明插件的"建 base"步骤确实执行过。

## 七、操作注意事项

- **`VBoxManage unregistervm <vm> --delete` 会一并删除其磁盘文件。** 复位实验环境时误用该
  命令,导致 `Database\vfw_usg.vdi`(988 MB)被删除,需重新复制。复位应使用不带 `--delete`
  的 `unregistervm`。
- **写给客户机的 `.ps1` 一律用纯 ASCII。** 宿主写出的文件不带 BOM,客户机 PowerShell 5.1
  按 ANSI 解读,中文会被拆成乱码并引发解析错误(表现为 "字符串缺少终止符")。
- **自删陷阱**:用 `Get-CimInstance Win32_Process | Where CommandLine -match '<脚本名>'` 杀旧仪器时,
  当前 shell 的命令行里也含该脚本名,会把自己一起杀掉。需按 `$PID` 排除自身。

## 八、7.2 + 垫片上的对照实验(2026-09-12 凌晨)

在 inst-52(VBox 7.2.8 + 当前垫片 `9589D02D`)上把 `vfw_usg` 退为未注册、`.vdi` 留在
`Database\`,点一次「启动」。结果:**错误代码 40**,`vfw_usg` 仍未注册。

### 8.1 链路分化点

垫片日志显示的完整序列:

```
[clonecheck#1] base='vfw_usg' snap='vfw_usg_Link'
[clonecheck] Invoke(findMachine,'vfw_usg') hr=0x80020009   ← 未找到
[clonecheck#2] ... hr=0x80020009
[DIAG] get_APIVersion / get_settingsFilePath / get_homeFolder
[clonecheck#3] ... hr=0x80020009
VBoxManage unregistervm  --delete                          ← 之后停摆
```

插件确实生成了**正确的** `vfw_usg.vbox`(8741 字节,磁盘路径已是绝对路径,
machine uuid 与 5.2 黄金跑完全一致 `{12ec8fd1-…}`),但**没有把它注册进去**。

对比 5.2:同样的"未找到"结果,链路却继续走到了注册 → `snapshot delete/take` →
`clonevm --register` → `startvm`。**差别不在分支选择,而在注册这一步本身没做成。**

### 8.2 slot[1] 的调用约定 —— 已实测确认垫片是对的

曾怀疑 `thunk_clone_check` 的 `ret 0Ch` 与真品的 `mov eax,2; ret 4` 冲突,
会多弹 8 字节带偏调用方栈。**实测证伪,垫片是对的。**

三次调用的原始栈快照(靠新增的 `diag_clone_stack` 打印)显示三个 dword
全是真参数:

```
[clonestk] esp=023FF848 ret=1000E47D (ngfw_Plugin.dll+0xE47D)
[clonestk]   [0]=1000E47D  [1]=02D36F40  [2]=02D36EE8  [3]=023FF87C
                返回地址      base         snap         pOut
```

调用点全部位于 `ngfw_Plugin.dll`:`+0xE47D`、`+0xEBE2`(在 `RegisterDevice`
`0x1000EB40` 内)、`+0xCF7E`。反汇编 `+0xE47D` 处的宿主函数,其尾声是:

```asm
0x1000E4AC  pop  ecx                 ; 栈 cookie
0x1000E4AD  pop  esi
0x1000E4AE  pop  ebp
0x1000E4AF  add  esp, 0x34           ; 绝对量恢复,不依赖调用的平衡
0x1000E4B2  ret  4
```

`add esp,0x34` 是**绝对修正**。若 slot[1] 的弹栈量与调用方压入量不等,
后面三个 `pop` 会读到错值、`add` 也会落偏,函数将返回到垃圾地址而崩溃。
**实测无崩溃且函数正常返回并继续执行** —— 因此 `ret 0Ch` 对这个调用点是平衡的,
**调用方确实压了 3 个参数**。

**教训**:两处"看起来像参数"的 dword 实际是调用方刚在栈上构造的 CString 对象
(`mov [esp+0x24], esp` 是 ATL 的栈缓冲写法),仅凭内容无法区分参数与残留 ——
必须靠**调用点的 push 序列**或**尾声的栈纪律**来判定。

### 8.3 仍未定位的一环

注册动作在 5.2 上经由 COM 完成,但 7.2 + 垫片上**方法区槽位 `[25]`–`[49]` 一次都没被调用**
(`[DIAG]` 只出现属性 getter)。因此注册不是经由垫片的方法区 thunk 发出的。

原始日志存于 `analysis/golden52/`;本次对照实验的 `[clonestk]` 快照见
`vbox52_proxy.log`。

---

## 九、惰性注册:实测结论与 vtable 索引更正(2026-09-12)

沿 8.3 的线索动手:既然注册是 COM 调用而垫片的方法区 thunk 没被调用,那就**由垫片
自己发起**这次注册。触发点定在插件的克隆前置探测(proxy slot[1])报告"不存在"时 ——
插件此时已把 `tools\ngfw\vfw_usg.vbox` 写到磁盘上。

### 9.1 OpenMachine / RegisterMachine 的真实索引是 [51] / [52]

先按项目表试 `[39]`/`[40]`,实测:

```
[lazyreg] openMachine[39]('...vfw_usg.vbox') hr=0x80004001 machine=74517ED0
```

`0x80004001` 是 `E_NOTIMPL`,只有保留属性/保留方法才会这么返回。更糟的是
`[39]` 的真实形状是**单参 `(ULONG *retval)` 属性读取器**:它把传进去的路径 BSTR
当成输出指针写,随后 `SysFreeString` 触发写入 0 地址的 AV,`eNSP_VBoxServer.exe`
当场退出、eNSP 界面卡在 0%。崩溃现场 `EIP` 落在路径字符串里,`EAX=80004001`,
与该解释完全吻合。

改用 SDK typelib 的索引后:

```
[lazyreg] openMachine[51]('...vfw_usg.vbox') hr=0x00000000 machine=007BEE5C
[lazyreg] registerMachine[52] hr=0x00000000
[lazyreg] registered via [51]/[52]
[clonecheck] re-check after lazy registration: hr=0x00000000
```

两次调用均返回 `S_OK`,`vfw_usg` 随即出现在 `VBoxManage list vms` 中。

**⇒ 7.2.8 的 `OpenMachine` = `[51]`,`RegisterMachine` = `[52]`。**
项目自身表里的 `[39]`/`[40]` 偏低 12,与 `analysis/output/vbox728_vtable.md`
(SDK typelib 解析,方法区从 48 起)一致,而 `CLAUDE.md` 的 7.2 方法表漏掉了
`[36]`–`[47]` 这段 12 个保留属性。

**遗留矛盾(未解)**:`patches/var_plugin_ar1000v.md` 用的是同一张偏低 12 的表
(如 `findMachine 37→41`),而 AR 设备实测可用。两种可能:该插件实际未走到那些
调用点,或其可用性与补丁无关。**在弄清之前不要据本文结论去改 AR 补丁。**

### 9.2 只注册还不够 —— 必须同时补 `_Link` 快照

注册成功后链路确实往前走了,命令一路到:

```
clonevm vfw_usg --snapshot vfw_usg_Link --options link ... --register
modifyvm <clone> --uart1 off
modifyvm <clone> --uart2 0x2f8 3 --uartmode2 server \\.\pipe\...
startvm  <clone> --type headless
controlvm <clone> poweroff
```

但仍以 error 40 收场,插件日志:

```
[ERROR]CAgentStaticCfgProcess::Startup - Failed to create pipe.errorcode=2
```

**根因**:`vfw_usg` 没有任何快照(`This machine does not have any snapshots`),
而整轮里 `snapshot ... delete` / `snapshot ... take` 一次都没出现。

插件日志给出了原因 —— 开头两行 `Device has already existed.`。`FUN_1000eb40`
的第一分支是"设备已存在则短路返回",**该短路假设 VM 已经准备妥当,包括
`<base>_Link` 快照**。提前注册使插件走了这条短路,于是跳过它本该执行的两步建快照。

⇒ 惰性注册必须把 VM 留在短路分支所假设的状态:**注册 + 补 `<base>_Link` 快照**。
补快照经由 `VBoxManage snapshot <base> take <base>_Link` 同步执行;同名快照
`take` 会失败但无害,因此无需存在性检查,每进程只尝试一次。
