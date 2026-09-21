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
| `01_version_spoof.reg`      | 在 64 位和 32 位两个视图里，把 `Oracle\VirtualBox` 的 `Version` 与 `VersionExt` **都**设为 5.2.44，好让 eNSP 的 5.2.x 版本闸门放行（机器实际跑的是 7.2.x）。两个值必须逐字相同、不带构建号：eNSP 读 `VersionExt` 时复用了 `InstallDir` 的缓冲区长度，`VersionExt` 一旦比 `InstallDir` 长，读取即失败 |
| `02_clsid_inprocserver.reg` | 在两个视图里把 `CLSID_VirtualBox` `{B1A7A4F2-…}` 的 InprocServer32 重指到 `…\Huawei\eNSP\tools\VBox52.dll`，这样 eNSP 的 32 位 `CoCreateInstance` 加载的是垫片，而不是 VBox 自带的 proxy/stub |

卸载没有对应的静态 `.reg`：要把版本字符串还原成**本机** VirtualBox 的真实版本，而这个值只能现场读，写不进静态文件。用 `卸载.bat`（现场跑 `VBoxManage --version` 取值后回填）。

## 路径

这些 .reg 文件用的是标准安装位置：

- eNSP：`C:\Program Files\Huawei\eNSP\tools\VBox52.dll`
- VirtualBox：`C:\Program Files\Oracle\VirtualBox\`

如果你的安装在别处，导入前先改路径。

## 前提

- 已装好 VirtualBox **7.2.x**（二进制必须真的是 7.2；只有注册表在假装 5.2）。
- `VBox52.dll` 已编译并拷到 `…\eNSP\tools\`（见 `build/`）。

## 卸载

1. 把版本字符串放回真实的 7.2.x。用 `卸载.bat`——它现场执行
   `VBoxManage --version` 取值后回填 `Version` 与 `VersionExt`（两个视图、两个值都取行首的
   `主.次.修订`，不带 `r` 构建号）。手工等价操作：读出该值后自己写回
   `HKEY_LOCAL_MACHINE\SOFTWARE\Oracle\VirtualBox` 与 `…\WOW6432Node\…`。
2. 还原 VirtualBox 自带的 COM 注册。垫片覆盖了 `CLSID_VirtualBox` 的
   InprocServer32，而这个键归 Oracle 的安装程序所有。把正确的值放回去，权威的
   做法是在「应用和功能」里对 VirtualBox 7.2.x 跑一次**修复**（或重装）。它会
   替你把这个 CLSID 改回 VBox 自己的 32 位 proxy/stub
   （`…\Oracle\VirtualBox\x86\VBoxProxyStub-x86.dll`）。

   我们故意不提供一份写死该路径的 .reg：它随 VBox 构建版本而变，填错值会让
   COM 崩掉。让 Oracle 自己的安装程序去改写它，才是安全的还原方式。

## 为什么要两个视图

eNSP 是 32 位进程，但它用 `KEY_QUERY_VALUE | KEY_WOW64_64KEY`（掩码 `0x101`）打开这个键，
**读的是 64 位视图**（语料 30 个模块里 22 处打开点，掩码无一例外）。32 位视图也写一份，
供读它的工具使用——eNSP 自己不看那里。
