# 测试夹具来源说明

这些文件是**真机命令输出的原样捕获**，供 `build/tests/` 下的解析器测试使用。
全部捕获于 2026-09-15，机器状态为 VirtualBox 7.2.16 安装完好（网络驱动已正确注册）。

| 文件 | 来源 | 说明 |
|---|---|---|
| `vboxdrvinst_healthy.txt` | `VBoxDrvInst.exe list` | 健康基线。含 `VBoxNetAdp6.NTAMD64` 与 `VBoxNetLwf.NTAMD64` 两类型号行，共 76 个驱动包 |
| `vboxdrvinst_missing.txt` | 由上者派生 | 删去上述两类型号行，模拟驱动未注册 |
| `hostonlyifs_normal.txt` | `VBoxManage list hostonlyifs` | 接口名为干净的 `VirtualBox Host-Only Ethernet Adapter` |
| `hostonlyifs_suffixed.txt` | 由上者派生 | 接口名带 `#2` 后缀 |
| `dhcpservers_normal.txt` | `VBoxManage list dhcpservers` | 单个 DHCP 服务器，`Enabled: Yes` |
| `netadapter_normal.txt` | `Get-NetAdapter \| ConvertTo-Json` | 连接名为本地化字串（抓取时为「以太网 11」），`InterfaceDescription` 为稳定键 |

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

### 3. 网卡连接名是本地化的

`netadapter_normal.txt` 的 `Name` 字段是抓取时的系统语言（中文）。这是刻意的——
它正是「**不可按连接名匹配，只能用 `InterfaceDescription` 关联**」这条设计决策的证据。
