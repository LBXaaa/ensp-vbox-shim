# 排错:eNSP 设备启动「错误 40」

「错误 40 / 设备启动失败」是 eNSP 的**通用启动失败码**,不是单一根因。它在原生 eNSP + VirtualBox 环境里也常见,并非本垫片引入。下面按已确认的根因分类,每类给出辨别方法与修复。

> 共性前提:eNSP 的交换机(S 系列 LSW)、PC、AC 等是华为轻量模拟进程,**不走 VirtualBox**;只有 **AR 路由器、部分 FW/AC** 是真正的 VirtualBox 虚拟机。所以「错误 40」绝大多数只发生在 **AR 这类真 VM 设备**上,交换机/PC 不受影响。

---

## 根因 A:缺 x86 VC++ 运行时 / 进程加固(干净机最常见)

**现象**:刚装好、首次拉 AR 就报 40;日志里可见 `0x800700C1` 或加固相关 `rc=-5657`。

**根因**:两层独立问题——
1. COM 层:VBox 的 x86 进程内激活缺 `VCRUNTIME140.dll` / `MSVCP140.dll`(干净机普遍没装 x86 VCRT)→ `0x800700C1`。
2. startvm 层:VirtualBox 进程加固(hardening)拒绝加载非 Oracle 签名的 DLL。

**修复**:整合包 `安装.bat` 已自动处理——把 x86 VCRT 拷进 `VirtualBox\x86\`(**只能放 x86\ 子目录**,往主目录塞 x64 版是有害误诊)。手动安装见 README「手动安装」第 4 步。

---

## 根因 B:基础 VM 未注册 / 缺链接克隆快照(卸载重装后常见)

**现象**:设备一拖就报 40;`注册设备.bat` 显示 VM 注册项指向失效路径,或基础盘缺 `<VM>_Link` 快照。

**根因**:eNSP 链接克隆要求每个基础盘(`AR_Base` 等)带一个 `<VM>_Link` 快照作为克隆源。没卸载干净就重装时,残留的注册项 / `VirtualBox.xml` 条目与新基础盘 UUID 冲突,克隆源失效。

**修复**:用**平时启动 eNSP 的登录账户**(不要用管理员)双击 `注册设备.bat`(`installer/register_vms.ps1`),它按需重注册并补建缺失的 `<VM>_Link` 快照。幂等、可逆。

---

## 根因 C:嵌套环境下 VBox 走原生 VT-x,guest 内核确定性 panic(本文重点)

**适用范围**:eNSP 跑在**嵌套虚拟化**环境里(宿主 Hyper-V + 客户机 Windows 内再跑 eNSP),且该客户机内 **VBox 拿到了裸 VT-x、走原生 HM 后端**时。物理机、或客户机已启用 WHP(VBox 走 NEM)时不触发。

### 现象
- AR 启动后 eNSP 进度条满屏 `####` **永不结束**(看着像"一直在启动",实为 guest 已崩、eNSP 在傻等)。
- 任务管理器里 `VBoxHeadless` 持续吃 30~50%+ CPU **不回落**(单核被打满)。
- guest VGA / AR 控制台可见 Linux 内核 panic:固定崩在 `EIP c013e501`,`CR2 0xfffffffc`,故障指令 `mov eax,[eax-4]`(空指针),末尾 `Fixing recursive fault but reboot is needed!`。
- 多台同开时叠加触发「错误 40」,但**单台、全新克隆、低负载照样崩**——与并发量无关。

### 根因(实测坐实)
病根在 **host 的执行后端选择**,不在 guest、不在差分盘、不在并发量:

1. 客户机 Windows 拿到宿主透传的裸 VT-x → 该机内 VBox 7.x 默认走**原生嵌套 HM/VT-x**(`HM: Enabled unrestricted guest execution`)。
2. 二级嵌套下的 unrestricted-guest 跑 eNSP 古董 32 位 VRP 内核(TinyCore Linux 3.0.21)的实模式→分页早期启动**有缺陷** → guest 内核确定性 panic 在 `c013e501`(`eax=0` → `mov eax,[eax-4]` → CR2=`0xfffffffc`)。
3. 内核 `recursive fault` 后陷入死循环 → **空转烧满一个核** → eNSP 进度条永远等不到 guest 就绪。

**判定铁证 = 崩溃地址在任何 guest 配置下逐字节恒定**,改 guest 配置全程无效 → 病根不在 guest 层,在执行后端。

### 如何确认是这一类(而非垫片 bug / 差分盘问题)
用以下证据排除「垫片/VBox7 兼容」和「差分盘损坏」嫌疑,可照做核验:
- **母盘没坏**:对比两台同源实例的 `AR_Base.vdi` SHA256 —— 逐字节相同(本例均为 `0e001ea4…9e3ce3`)。
- **差分盘无辜**:用**全新克隆、全新差分盘、单台、低负载**启动,**照样崩在同一 `c013e501`** → 排除"高压写坏差分盘"假设。
- **并发无辜**:崩溃与同开台数无关,单台即崩 → 排除"CPU/IO 饿死"假设。
- **对配置免疫**:逐项实测 `--paravirtprovider legacy`(关 KVM pvclock)、`--nestedpaging off`、`--x2apic off`、`--cpu-profile` 换老 CPU —— **全部仍崩在同一 `c013e501`** → 病根不在 guest 配置。
- **后端是唯一变量**:走原生 VT-x(`Using execution engine 1` + `VT-x w/ nested paging`)必崩;切到 NEM(下方修复)即正常启动到 `<Huawei>`。
- **健康对照**:同一母盘在走 NEM 的实例上,guest 内核干净启动到 `box login`(TinyCore 3.0.21),CPU 从满核空转跌到 idle。

### 修复(让 VBox 走 NEM 后端)
核心:夺走 VBox 的裸 VT-x,逼它 fallback 到 NEM(Hyper-V/WHP 接管 CPU 虚拟化),绕开原生 VT-x 的 bug。

1. **宿主**给这台客户机暴露嵌套虚拟化(Hyper-V 宿主:`Set-VMProcessor <VM> -ExposeVirtualizationExtensions $true`,VM 须先关机)。否则客户机内连 VMX 都没有,AR 会报「错误 40 / VERR_NEM_NOT_AVAILABLE」起都起不来。
2. **客户机内**启用 WHP 并重启:
   ```powershell
   Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -NoRestart
   # 重启客户机(必须,装功能 ≠ 运行时上线)
   ```
3. 重启后客户机内 VMX 对 VBox **不再可见**(`VirtualizationFirmwareEnabled=False`、`HypervisorPresent=True`)=WHP 已接管 VT-x 的铁证。
4. **验证**:启动任一 AR,VBox.log 应出现 `HM: HMR3Init: Attempting fall back to NEM: VT-x is not available` + `NEM: ...HypervisorPresent is TRUE`;guest 不再 panic,进度条跑完,设备进 `<Huawei>` CLI;`VBoxHeadless` CPU 从满核空转跌到 idle。

> WHP 是**全局后端选择**,启用后**每台新克隆自动走 NEM**,无需逐台设 `UseNEMInstead`。仅当 VT-x 对 VBox 仍可见(不强制就选 HM)时,才需要 `VBoxManage setextradata <vm> "VBoxInternal/HM/UseNEMInstead" "1"`。

### 预防
- 嵌套环境部署 eNSP 前,先在客户机启用 WHP,确保 VBox 走 NEM。
- 物理机或非嵌套环境不触发此类(VBox 用裸 VT-x 但无二级嵌套缺陷)。
- NEM 比 HM 慢(`Snail execution mode`),AR 启动更久但能正常跑完;给客户机多分 vCPU/内存可缓解。

---

## 速查表

| 现象 | 根因 | 去看 |
|------|------|------|
| 干净机首拉 AR 即 40,`0x800700C1` | 缺 x86 VCRT / 加固 | 根因 A |
| 卸载重装后 40,注册项失效/无快照 | 基础 VM 注册/快照 | 根因 B,跑 `注册设备.bat` |
| 嵌套环境 AR 进度条卡满屏 `####`,headless 空转满核,内核 `c013e501` panic | VBox 走原生 VT-x,二级嵌套下崩 | 根因 C,启用 WHP 让 VBox 走 NEM |
