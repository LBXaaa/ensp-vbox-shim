# 一键整合包 · installer/

让原版华为 eNSP 直接跑在 VirtualBox 7.x 上。**解压 → 双击 → 搞定**,自动检测 eNSP / VirtualBox 安装位置,无需手动改注册表或拷文件。

## 目录内容

| 文件 | 作用 |
|------|------|
| `安装.bat` | 安装入口。双击即可,自动请求管理员权限(UAC) |
| `卸载.bat` | 卸载/还原入口。双击即可,自动提权 |
| `注册设备.bat` | 注册基础设备 VM 到 VirtualBox。**不提权**,用平时启动 eNSP 的账户双击 |
| `install.ps1` | 实际干活的 PowerShell 脚本(被上面两个 .bat 调用) |
| `register_vms.ps1` | 注册脚本(被 `注册设备.bat` 调用) |
| `payload/VBox52.dll` | 预编译好的 COM/vtable 垫片,安装时拷进 eNSP\tools\ |

## 怎么用

### 安装

1. 先装好**原版** eNSP 和**官方** VirtualBox 7.2.x(本仓库不附带它们)。
2. 双击 **`安装.bat`**。
3. 弹出 UAC 窗口点"是"(写注册表 + 改 Program Files 需要管理员权限)。
4. 看窗口里的 4 步是否都 ✓,结束后启动 eNSP 拉一台设备试试。

### 注册设备 VM(设备起不来时)

eNSP 在 VirtualBox 7.x 上**无法自动注册**基础设备 VM(`AR_Base`、`WLAN_*_Base`),这些是拖设备时的克隆源,没注册上设备就起不来;`安装.bat` 不做这步。**用平时启动 eNSP 的账户**(不要用管理员)双击 **`注册设备.bat`**:扫 `vboxserver\` 下的基础盘,未注册的注册、已注册的先注销再重注册一遍(清掉半坏的注册状态)。幂等、可逆——注销不加 `--delete`,不动磁盘。

只想看会做什么、不改动:

```powershell
powershell -ExecutionPolicy Bypass -File register_vms.ps1 -Check
```

为什么不提权:VM 注册写入当前用户的 `.VirtualBox\VirtualBox.xml`,必须与启动 eNSP 的账户一致;用管理员跑可能写进别的账户、eNSP 反而看不到。

### 卸载还原

双击 **`卸载.bat`**,会还原版本字符串、还原 AR 插件、删除垫片 DLL。CLSID 项需要手动跑一次 VBox 修复(见下方"卸载的最后一步")。

### 只检测不改动

想先看看当前机器是什么状态,不做任何改动:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Check
```

会打印 eNSP/VBox 路径、垫片 DLL 是否就位、注册表版本号、CLSID 指向、VAR_Plugin.dll 是出厂版还是已打补丁。

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

**双击没反应 / 一闪而过** —— 多半是 UAC 被拒。右键 `安装.bat` → 以管理员身份运行,看报错。

**提示"需要管理员权限"** —— 没经 `.bat` 提权直接跑了 `.ps1`。请双击 `.bat`,或在管理员 PowerShell 里跑。

**"未能自动定位 eNSP 安装目录"** —— 用 `-EnspDir` 手动指定(见上)。

**窗口中文乱码** —— `.bat` 已按 GBK + `chcp 936` 编码,正常不会乱;若仍乱码,通常是把文件用别的编辑器另存改了编码。

**装完 eNSP 仍报版本错误** —— 跑一次 `-Check`,确认注册表 `Version` 是否已是 `5.2.44`、CLSID 是否指向 tools 下的 DLL。

**设备启动很慢(单台 3-5 分钟)** —— 正常现象,不是卡死。本机开了 WSL2/Hyper-V 时,VirtualBox 7.x 用不了 VT-x 硬件加速,只能跑在 Hyper-V 之上,虚拟机启动会明显变慢。点完"开始"耐心等,设备最终会起来。

## 系统要求

- Windows(脚本用系统自带 PowerShell 5.1,无需额外装运行时);
- 已安装原版 eNSP 与官方 VirtualBox 7.2.x;
- 管理员权限(`.bat` 会自动申请)。
