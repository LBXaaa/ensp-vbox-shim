# patches/

施加到 **华为 eNSP** 文件上的二进制补丁,让它们与 VirtualBox 7.x 协作。这里的
脚本就地修改**你自己**已经装好的那份拷贝,不依赖也不分发华为或 Oracle 的主程序。

## 文件

| 文件 | 用途 |
|------|------|
| `patch_var_plugin.py`   | 施加 / 还原 VAR_Plugin.dll 的 vtable 重映射 |
| `var_plugin_ar1000v.md` | 完整规格：28 个调用站点、槽位推导、指令形态 |

## VAR_Plugin.dll（ar1000v）

AR 路由器插件会通过写死的 **5.2** vtable 偏移去调用真实的 7.2 `IVirtualBox`。
在 7.x 上这些偏移会打到错误的方法，AR 一启动就崩。这处补丁把 28 个分派站点
（29 字节）改写到正确的 7.2 槽位。它只改 `call [reg+disp]` 里的位移字节——
文件大小不变，改动完全可逆。

```bat
:: 查看（只读）
python patch_var_plugin.py --check   "C:\Program Files\Huawei\eNSP\plugin\ar1000v\VAR_Plugin.dll"

:: 打补丁（会先在 dll 旁边写一份 .bak）
python patch_var_plugin.py           "C:\Program Files\Huawei\eNSP\plugin\ar1000v\VAR_Plugin.dll"

:: 还原
python patch_var_plugin.py --restore "C:\Program Files\Huawei\eNSP\plugin\ar1000v\VAR_Plugin.dll"
```

### 安全保证

- 补丁器只接受 **2019 出厂版**（大小 393216，原始 SHA256 `5ae6817a…`）。其它
  一律拒绝。
- 写入前，会逐一核对每个目标字节是否仍是补丁前的预期值（在整文件哈希之上再加
  一层纵深防御）。
- 写入后，会对结果重新求哈希，必须等于已知的补丁后 SHA256（`f0107975…`），
  否则不保存。
- 除非你加 `--no-backup`，否则都会先做一份 `.bak`。

### 环境要求

- Python 3.x
- 插件是 32 位的；但补丁与架构无关（它只改字节），所以不需要任何工具链——
  有 Python 就行。
