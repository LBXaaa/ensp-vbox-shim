---
name: 设备起不来 / 报错
about: 设备启动失败、报「错误 40」、卡进度条、进不了 CLI
title: '[报障] '
labels: bug
---

<!--
  两条能让排查快很多,其余能填多少填多少:
    1. 附上 环境检查.bat 的报告
    2. 跑一次 VBoxManage startvm,看绕开 eNSP 是否也失败
-->

## 一、诊断报告(最重要)

把 **`环境检查.bat`** 产出的报告文件拖进来:

```
%ProgramData%\ensp-vbox-shim\diag-<时间戳>.txt
```

报告里已经有:系统版本与构建号、四个垫片投放点的哈希、CLSID 指向、host-only 网络六层、
基础 VM 注册与 `<VM>_Link` 快照、以及最近一次启动的 `VBox.log` / `VBoxHardening.log` 尾部。
**有了它就不必再手工收集这些。**

> 必须用**平时启动 eNSP 的那个账户**运行它。它读的是该账户的 `%USERPROFILE%\.VirtualBox\`;
> 换别的管理员账户跑,读到的不是 eNSP 实际用的那一份,结论会对不上。
>
> 报告全程只读、不含交互记录,可以原样附出来。

## 二、绕开 eNSP 再试一次

在命令行(不需要管理员)里跑:

```
"C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm <出问题的VM名> --type headless
```

VM 名从诊断报告里抄,或 `VBoxManage list vms`。

- [ ] 直接跑**也失败** —— 问题不在 eNSP,多半也不在本垫片
- [ ] 直接跑**能起来**,只有经 eNSP 才失败 —— 与本垫片相关

**这一条能把排查范围直接砍一半。** 失败了就把输出贴上来。

## 三、环境

| 项 | 怎么取 |
|---|---|
| 系统版本与构建号 | `winver`,例:Windows 11 专业版 25H2,26200.9457 |
| 最近装的更新 | `Get-HotFix \| Sort-Object InstalledOn \| Select-Object -Last 5` |
| VirtualBox 版本 | `VBoxManage --version` |
| 垫片版本 | 例:v0.2.0-beta |
| eNSP 版本 | |
| Hyper-V / WSL2 | 启用 / 未启用 |
| 出问题的设备 | 例:AR2220、USG6000V、CE12800 |

> 构建号请写到小数点后那几位,不要只写「Win11 最新」。同一个分支的相邻 build 表现可能
> 完全不同 —— issue #8 就是 `26200.8457` 能用、`26200.9168` 不能用,而两者只差两次月度更新。

## 四、现象

- 什么时候开始的?之前能用吗?
- 全新安装,还是从旧版升上来的?
- 点了什么之后出现的?每次都复现吗?
- 进度条停在哪、有没有弹框、设备图标显示什么?

## 五、已经排除过的

试过什么、结果如何。**列出来能省掉大量来回问。**

## 六、补充日志

有就先贴。提示一条:`VBoxHardening.log` 的**开头**比末尾有用 —— 末尾只写最终失败,
进程启动时对 token / SID / 权限的枚举在前面。
