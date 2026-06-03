# 把"注册基础设备 VM"合并进一键安装 — 设计

日期:2026-06-03
状态:已通过设计评审,待实现

## 背景与目标

当前用户装好 shim 后要点**两次**:先双击 `安装.bat`(打补丁),再单独双击 `注册设备.bat`(把
AR_Base / WLAN_*_Base 注册进 VirtualBox 7.x)。目标:**让用户只点一次**,注册自动跟在安装后面。

## 核心约束(为什么不能简单地在 install 末尾调 register)

两个脚本天生活在**两个不同的权限上下文**:

- `install.ps1` 写 **HKLM 注册表 + 覆盖 Program Files 下的 DLL**,是**机器级**改动,必须**提权**
  (`Assert-Admin` 强制管理员)。当前经 `安装.bat` 的 `Start-Process -Verb RunAs` 自提权。
- `register_vms.ps1` 把 VM 注册写进 **`%USERPROFILE%\.VirtualBox\VirtualBox.xml`**,是**用户级**
  数据,**必须用平时启动 eNSP 的那个普通用户令牌**写。脚本头明确警告:用管理员身份跑可能写进
  *别的*账户的 profile、eNSP 看不到注册的 VM。

关键认识:**提权改变的是令牌权限,不是用户身份 / `%USERPROFILE%` 路径。** 同一用户提权后
profile 不变;只有"换成另一个管理员账户"提权时 profile 才变。

## 账户场景矩阵(判据的依据)

| 场景 | 进程是否提权 | 当前 SID vs 登录用户 SID | 注册是否安全 |
|------|:--:|:--:|:--:|
| 管理员账户双击(UAC 开) | 否(过滤令牌) | 相等 | ✅ |
| 标准用户双击(UAC 开) | 否 | 相等 | ✅ |
| 管理员账户(UAC 关)双击 | 是(默认满令牌) | 相等 | ✅ |
| 管理员右键"以管理员身份运行" | 是 | 相等 | ✅ |
| 标准用户右键 + 借另一个管理员 | 是 | **不等** | ❌ 会写错 profile |

唯一会写错 profile 的是最后一行。判据因此**只看 SID 是否相等,不看是否提权**——这样连"UAC 关闭、
管理员默认满令牌"这种"进程已提权但仍是登录本人"的场景也判对。

## 架构:外层 bat 翻转为非提权编排器(方案 A)

`安装.bat` **不再自我提权**,保持在"双击它的那个用户"上下文里,新增一个非提权编排器
`install_all.ps1` 串起两段:

```
用户双击 安装.bat (非提权,= 登录用户)
  └─> install_all.ps1 (非提权)
        ├─ 第1段: Start-Process install.ps1 -Verb RunAs -Wait  → UAC 弹1次,写 HKLM+ProgramFiles
        └─ 第2段: SID 判定后跑 register_vms.ps1 (仍非提权,= 登录用户) → 写对 %USERPROFILE% ✓
```

register **从没被提权过**,所以管理员 / 标准用户**通杀**,零降权技巧;UAC 仍只弹 1 次。

### 文件职责

| 文件 | 改动 | 职责 |
|------|------|------|
| `安装.bat` | 改瘦:删自提权块,改成 `chcp + cd + 调 install_all.ps1` | 非提权启动器 |
| `install_all.ps1` | **新增** | 编排器:①提权跑 install.ps1 ②SID 判定后跑 register_vms.ps1 |
| `install.ps1` | 仅加 2 行 `Start-Transcript` 日志(独立提权窗口一闪而过,失败需留证) | 机器级补丁,始终提权 |
| `register_vms.ps1` | 不动 | 用户级注册,被编排器复用,也仍是手动后备 |
| `注册设备.bat` | 不动 | 边路后备:SID 不匹配时提示用户用本账户手动点它 |
| `卸载.bat` | 不动 | — |

## 注册判定逻辑(SID 比对)

```
$curSid         = 当前进程 user SID
$interactiveSid = 活动控制台会话里 explorer.exe 属主 SID(= 登录用户),经 CIM GetOwnerSid 取
若 $curSid == $interactiveSid  → 同一人,跑 register_vms.ps1
若 $curSid != $interactiveSid  → 借了别的管理员,跳过 + 黄字提示用登录账户双击 注册设备.bat
```

## 失败处理与退出码

两段有依赖顺序:install 失败就不跑 register。

- **install 段**:`Start-Process ... -Verb RunAs -Wait -PassThru`,读子进程 `ExitCode`。
  - UAC 点"否" → `Start-Process` 抛异常 → 编排器捕获,打印"安装需要管理员权限,已取消",退出,不跑注册。
  - install 自身 `exit 1`(没定位到 eNSP 等) → ExitCode≠0 → 报"安装步骤失败,跳过注册",并指向
    install transcript 日志路径,退出。
- **register 段**(仅 install 成功后):register_vms.ps1 自带逐台 VM 容错(注销失败不动、重注册失败
  打恢复命令),编排器不吞其输出。register 整体失败**不回滚 install**(install 已成功,注册可重试)。
- **SID 不匹配边路**:不算失败,正常退出,黄字提示"安装已完成;请用平时启动 eNSP 的账户双击
  注册设备.bat 完成注册"。

## 测试与验证

PowerShell 脚本 + 提权,无单测框架。靠语法校验 + 真机走查:

- **语法**:对 `install_all.ps1` 跑 `[Parser]::ParseFile`,确保 PARSE OK。
- **SID 取值单独验证**:单跑取 `$interactiveSid` 的表达式,确认能拿到登录用户 SID(不为空)——
  这是全套逻辑的命门,单独验明。
- **真机走查(用户来点)**:双击 `安装.bat` → UAC 弹 1 次 → 装完自动注册 → 进 eNSP 看 5 台
  Base VM 在不在、拉一台 AR 起得来。唯一权威的端到端验证。
- 不引入新测试框架(YAGNI)。

## 不做(YAGNI)

- 不删 `注册设备.bat`(留作边路后备 + 手动重试入口)。
- 不做降权(WTSGetActiveConsoleSessionId 跑提权进程里启动子进程那套),方案 A 不需要。
- 不改 `卸载.bat`、不改 `register_vms.ps1` 内部逻辑。
