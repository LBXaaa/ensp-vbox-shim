# 测试夹具来源说明

这些文件是**真机命令输出的原样捕获**，供 `build/tests/` 下的解析器测试使用。
捕获于 2026-09-15 与 2026-09-16，机器状态为 VirtualBox 7.2.16 安装完好
（网络驱动已正确注册、eNSP 1.3.00.100 已装、垫片已装）。

> **形如 `{aaaaaaaa-0001-4001-8001-000000000001}` 的标识符都是合成值。**
> 抓取时机器上的真实 VM / 快照 / 镜像 UUID 已整体替换，替换在同一夹具组内保持一致
> （同一个 VM 在各文件里仍是同一个 UUID）。解析器只看形状，不看具体值。
>
> 未替换的两类：`vboxdrvinst_*.txt` 里的 `{DD8E82AE-…}` / `{084F01FA-…}` 是微软
> 与 Intel 写在 INF 里的固定硬件 ID，每台机器都一样；`checks.ps1` 注释里的
> `{0f3e5d1c-…}` 是文档示例。

| 文件 | 来源 | 说明 |
|---|---|---|
| `vboxdrvinst_healthy.txt` | `VBoxDrvInst.exe list` | 健康基线。含 `VBoxNetAdp6.NTAMD64` 与 `VBoxNetLwf.NTAMD64` 两类型号行，共 76 个驱动包 |
| `vboxdrvinst_missing.txt` | 由上者派生 | 删去上述两类型号行，模拟驱动未注册 |
| `hostonlyifs_normal.txt` | `VBoxManage list hostonlyifs` | 接口名为干净的 `VirtualBox Host-Only Ethernet Adapter` |
| `hostonlyifs_suffixed.txt` | 由上者派生 | 接口名带 `#2` 后缀 |
| `dhcpservers_normal.txt` | `VBoxManage list dhcpservers` | 单个 DHCP 服务器，`Enabled: Yes` |
| `netadapter_normal.txt` | `Get-NetAdapter \| ConvertTo-Json` | 连接名为本地化字串（抓取时为「以太网 11」），`InterfaceDescription` 为稳定键 |
| `vbox_list_vms.txt` | `VBoxManage list vms` | 五个基础设备 VM 全部注册的健康基线 |
| `vbox_machine_registry.xml` | `%USERPROFILE%\.VirtualBox\VirtualBox.xml` 的 `<MachineRegistry>` 段 | 注册路径的权威来源；注意 `src` 的大小写与反斜杠写法 |
| `vbox_snapshots_with_link.txt` | `VBoxManage snapshot AR_Base list --machinereadable` | 含 `AR_Base_Link`，即链接克隆所需的那一个快照 |
| `vbox_showvminfo_state.txt` | `VBoxManage showvminfo AR_Base --machinereadable` | 只截取了 `name=` / `VMState=` 几行；**`VMState="aborted"`** 是真实抓到的状态 |
| `arbase_uart_ok.vbox` | 真机 `AR_Base.vbox` 的两段 `<Hardware>` | 按真实顺序组装：**快照段在前、实况段在后**，两段的值**故意相反** |
| `arbase_uart_disabled.vbox` | 由上者派生 | 实况段的 slot 1 改成 `enabled="false"`，模拟 UART2 未开 |
| `arbase_vram_small.vbox` | 由上者派生 | 实况段 `VRAMSize` 改小成 8，快照段仍是 16 |
| `vboxlog_backend_native.txt` | 真机 `VBox.log` 逐字摘录 | 走原生 VT-x 的后端判定行 |
| `vboxlog_backend_nem.txt` | **按源码格式串构造** | NEM 回退 + Snail 模式 |
| `vboxlog_intnet_error.txt` | VirtualBox ticket #18260 的用户日志原文 | host-only 失败块；**两行**带 `VERR_INTNET_FLT_IF_NOT_FOUND` |
| `hardening_5657.txt` | **按源码格式串构造** | 加固拒绝一个 DLL 的完整形态 |
| `hardening_clean.txt` | **按源码格式串构造** | 无错误锚点的正常加固日志 |

> **构造 ≠ 编造。** 标「按源码格式串构造」的三份与两份 VBox.log 夹具，逐字取自
> `github.com/VirtualBox/virtualbox` 里对应的 `RTPrintf` / `RTLogRelPrintf` 格式串
> （核对于 2026-09-16），**不是**捕获所得。用它们是因为本机既没有加固失败的实例，
> 也没有走 NEM 的实例；而这两条路径恰恰是最需要能判出来的。**新增夹具时若手边有真机
> 样本，优先用真样本替换掉这几份。**

## 使用夹具时必须知道的几点

## 使用夹具时必须知道的几点

### 1. `vboxdrvinst_missing.txt` 只删了型号行，oem 行仍在

派生用的是按行过滤，因此 `oem90.inf | 08/13/2026` 与 `oem91.inf | 08/13/2026`
两行**仍留在文件里**，只是它们下面的型号行没了。也就是说该夹具描述的是
「INF 已登记但型号缺失」，**并非** 2026-09-15 的真实故障状态（当时
`pnputil /enum-drivers` 里一个 VBox 包都没有）。

**影响**：`Parse-VBoxDrvInstList` 按型号名匹配，对此免疫。
但**任何按 oem 文件名匹配、或统计 INF 块数量的探针都会被这个夹具误导**。
新增此类探针前，需要先重做一个更忠实的夹具。

### 2. 行尾是 CRLF 与孤立 CR 的混合

`VBoxDrvInst.exe list` 的输出中除 170 个 `CRLF` 外，还含约 167 个**不带 `\n` 的孤立 `\r`**
（控制台程序的常见行为）。因此：

- `wc -l` 与按 `\n` 切分得到的行数一致（170）
- 而 Python 的 `splitlines()` 会把孤立 `\r` 也当换行，得到约 339 行

用脚本改写这些夹具时要显式指定换行处理方式，否则会重排文件结构。
`Get-Content` 读入后交给解析器不受影响。

### 3. `VBoxNetworkName` 必须与 `Name` 同步变化

两个 `hostonlyifs` 夹具里，`VBoxNetworkName` 都等于 `HostInterfaceNetworking-` 拼上 `Name`
（这是真实 VBox 的构造规则）。因此 `hostonlyifs_suffixed.txt` 的该字段**也带 `#2`**。

**接线决策**：第 6 层的名字比对（`Compare-HostOnlyName`）**必须喂 `Name` 字段，不能喂
`VBoxNetworkName`**。理由有二：

1. eNSP 模板里写的是 `HostOnlyInterface name="VirtualBox Host-Only Ethernet Adapter"`，
   对应的是适配器**名**，不是 VBox 内部的网络名。
2. `VBoxNetworkName` 带 `HostInterfaceNetworking-` 前缀，与模板名格式不同，直接比对必然全不匹配。

`VBoxNetworkName` 的正确用途是**与 DHCP 服务器的 `NetworkName` 比对**（见 install.ps1
的 host-only 自检），那里两边都是完整形式。

### 4. 网卡连接名是本地化的

`netadapter_normal.txt` 的 `Name` 字段是抓取时的系统语言（中文）。这是刻意的——
它正是「**不可按连接名匹配，只能用 `InterfaceDescription` 关联**」这条设计决策的证据。

### 5. `.vbox` 里**快照段在前、实况段在后**——这是本组夹具存在的全部理由

真实 `.vbox` 在**每个 `<Snapshot>` 里重复整段 `<Hardware>`**，而且**顺序是反的**。
真机 `AR_Base.vbox`（2026-09-16 实测）：

```
行 24   <Snapshot uuid="{aaaaaaaa-0002-…}" name="AR_Base_Link" …>   ← 快照
行 25     <Hardware>
行 73     </Hardware>
行 74   </Snapshot>
行 75   <Hardware>                                              ← 实况
行 123  </Hardware>
```

**所以「取第一个 `<Hardware>`」拿到的是快照。** 这个错误在两道解析器里都真实存在过
（`Parse-UartPorts` 与 `Get-VramSizeFromTemplate`），而且**骗过了测试**——因为本机所有
模板两段的值恰好相同，读错哪一段结论都一样。

因此这三份夹具把两段的值**做成相反**，读错立刻现形：

| 夹具 | 快照段 | 实况段 | 断言要求 |
|---|---|---|---|
| `arbase_uart_ok` | UART 关、VRAM 8 | UART 开、VRAM 16 | 必须报 UART 可用、VRAM 16 |
| `arbase_uart_disabled` | UART 关、VRAM 8 | UART **关** | 必须报 UART 不可用 |
| `arbase_vram_small` | VRAM **16** | VRAM **8** | 必须报 VRAM 8 且判为过小 |

最后一行是反向的：读错就会拿到 16，把一个真坏了的模板报成正常。

`Get-LiveHardwareBlock` 逐**标签**扫描而不是逐行计数——单行写成
`<Snapshot …><Hardware>…</Hardware></Snapshot>` 时，逐行计数会让这一行自己把深度关掉又
打开，中间那个 `<Hardware>` 就被当成实况。这一条也是被夹具抓出来的。

### 6. `vbox_showvminfo_state.txt` 抓到的 `aborted` 不是制作的

2026-09-16 的 `AR_Base` 确实停在 `aborted`（异常终止），而这正是当时那个 bug 的成因：
旧版 `register_vms.ps1` 只认 `poweroff`，于是跳过补建快照。这个夹具因此同时钉住两件事——
解析器要能读出 `aborted`，且它必须被当作「可以补快照」而不是「设备还在跑」。

### 7. 新增夹具的编码

`arbase_uart_*.vbox` 与 `*.xml` 由 PowerShell 5.1 的 `Set-Content -Encoding UTF8` 写出，
**带 UTF-8 BOM**。`Get-Content` 读入时会剥掉它，解析器不受影响；但用别的工具按字节
处理时要记得它的存在。

### 8. 十进制 `rc=-NNNN` **只**在加固日志里

这是写日志解析器时最容易踩的一个坑，夹具也照着它设计：

- `VBoxHardening.log` 打的是十进制带负号：`Error -5657 in supR3HardenedWinReSpawn! (enmWhat=5)`
- `VBox.log` 打的是符号名：`rc=VERR_INTNET_FLT_IF_NOT_FOUND`
- `VBoxManage` 打的是 `code VERR_... (0x...)`

所以**在 VBox.log 里找裸的 `-5657` 永远找不到**。`vboxlog_intnet_error.txt` 正是用来
钉这一条的：把它喂给 `Parse-HardeningLog` 必须一无所获（`hardening: a VBox.log yields
no hardening verdict`）。谁要是把解析器改成也去扫 VBox.log，那条断言就会失败。

### 9. `vboxlog_intnet_error.txt` 里有**两行**命中，这是对的

`VMSetError: ...` 与 `PDM: Failed to construct 'e1000'/1! VERR_INTNET_FLT_IF_NOT_FOUND`
都带同一个错误码——后者是同一根因在设备侧的复述。`Find-VBoxLogMarkers` 是**查找器**，
两行都返回；把结论合并成一条是报告的职责。夹具因此断言 `Count = 2`。
