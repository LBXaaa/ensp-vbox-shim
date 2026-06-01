# registry/

把 eNSP 接到垫片上的 Windows 注册表改动。它们在一台全新机器上，复现垫片安装
所做的两处注册表层面的改动。所有值都已对照一份活的、能正常工作的安装核验过。

导入顺序有讲究：**先版本伪装，再 CLSID 劫持**。

```bat
reg import 01_version_spoof.reg
reg import 02_clsid_inprocserver.reg
```

（或者双击每个 .reg。需要管理员权限——它们写的是 HKLM。）

## 每个文件做什么

| 文件 | 作用 |
|------|------|
| `01_version_spoof.reg`      | 在 64 位和 32 位两个视图里，把 `Oracle\VirtualBox` 的 `Version` 设为 5.2.44、`VersionExt` 设为 5.2.44r139111，好让 eNSP 的 5.2.x 版本闸门放行（机器实际跑的是 7.2.8） |
| `02_clsid_inprocserver.reg` | 在两个视图里把 `CLSID_VirtualBox` `{B1A7A4F2-…}` 的 InprocServer32 重指到 `…\Huawei\eNSP\tools\VBox52.dll`，这样 eNSP 的 32 位 `CoCreateInstance` 加载的是垫片，而不是 VBox 自带的 proxy/stub |
| `99_uninstall.reg`          | 把真实版本字符串还原回去（7.2.8 r173730）。它**不**撤销 CLSID 劫持——见下文 |

## 路径

这些 .reg 文件用的是标准安装位置：

- eNSP：`C:\Program Files\Huawei\eNSP\tools\VBox52.dll`
- VirtualBox：`C:\Program Files\Oracle\VirtualBox\`

如果你的安装在别处，导入前先改路径。

## 前提

- 已装好 VirtualBox **7.2.x**（二进制必须真的是 7.2；只有注册表在假装 5.2）。
- `VBox52.dll` 已编译并拷到 `…\eNSP\tools\`（见 `build/`）。

## 卸载

1. `reg import 99_uninstall.reg` —— 把版本字符串放回 7.2.8。
2. 还原 VirtualBox 自带的 COM 注册。垫片覆盖了 `CLSID_VirtualBox` 的
   InprocServer32，而这个键归 Oracle 的安装程序所有。把正确的值放回去，权威的
   做法是在「应用和功能」里对 VirtualBox 7.2.8 跑一次**修复**（或重装）。它会
   替你把这个 CLSID 改回 VBox 自己的 32 位 proxy/stub
   （`…\Oracle\VirtualBox\x86\VBoxProxyStub-x86.dll`）。

   我们故意不提供一份写死该路径的 .reg：它随 VBox 构建版本而变，填错值会让
   COM 崩掉。让 Oracle 自己的安装程序去改写它，才是安全的还原方式。

## 为什么要两个视图

eNSP 是 32 位进程，所以它读的是 `WOW6432Node`（32 位）注册表视图。64 位视图
也设成一致，以便任何检视 VirtualBox 的 64 位工具也能读到。
