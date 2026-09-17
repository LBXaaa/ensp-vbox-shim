# patches/

施加到 **华为 eNSP** 文件上的二进制补丁,让它们与 VirtualBox 7.x 协作。这里的
脚本就地修改**你自己**已经装好的那份拷贝,不依赖也不分发华为或 Oracle 的主程序。

## 文件

| 文件 | 用途 |
|------|------|
| `patch_var_plugin.py`   | 施加 / 还原 VAR_Plugin.dll 的 vtable 重映射 |
| `patch_ngfw_plugin.py`  | 施加 / 还原 NGFW_Plugin.dll 的 vtable 重映射 |
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

## NGFW_Plugin.dll（USG6000V）—— 备查，**不在安装范围内**

> **安装器不会运行这个补丁器，也不需要运行。** 2026-09-10 的受控 A/B
> （inst-51，VBox 7.2.14，其余条件完全一致）：
>
> | 测试 | `NGFW_Plugin.dll` | 结果 | VM 存活 |
> |---|---|---|---|
> | A | 22 站点补丁版 | error 40 | 5547 ms |
> | B | 出厂原版 | error 40 | **5546 ms** |
>
> 失败签名逐字相同（`startvm` 后约 4 秒插件超时 → `controlvm poweroff` +
> `unregistervm --delete`），相差不到 1 毫秒。而在 host（VBox 7.2.x）上，
> **出厂原版即可正常启动 USG6000V**，进到 `Login authentication / Username:`。
>
> 也就是说：这个补丁既非充分，也未见必要。留在这里只为备查。

原始推导（供参考）：NGFW 与 AR 插件一样，会绕过 `VBox52.dll` 代理，直接用
VBox 5.2 的 `IVirtualBox` 位移调用真实 VBox 7.x 接口。补丁器只改经过反汇编
确认的 22 个 `IVirtualBox` 调用站点（23 个字节，因为 `checkFirmwarePresent`
的位移跨越 `0xFF`）；另外 6 个使用相同位移、但据判断属于 NGFW 自有对象的
调用点被排除。

> 那 6 个排除点本身存疑：它们在 `VAR_Plugin.dll`（已证实可用的 AR 生产补丁）
> 里有**指令形状完全一致**的对应点（其中 4 个偏移完全相同、周围代码 98–100%
> 逐字节相同），而 VAR 的生产补丁**确实**重写了它们。所以"排除"的依据并不牢靠。
> 既然补丁整体已被证明无关紧要，这个分歧也就不必再论。

```bat
:: 查看（只读）
python patch_ngfw_plugin.py --check   "C:\Program Files\Huawei\eNSP\plugin\ngfw\NGFW_Plugin.dll"

:: 打补丁（会先在 dll 旁边写一份 .bak）
python patch_ngfw_plugin.py           "C:\Program Files\Huawei\eNSP\plugin\ngfw\NGFW_Plugin.dll"

:: 还原
python patch_ngfw_plugin.py --restore "C:\Program Files\Huawei\eNSP\plugin\ngfw\NGFW_Plugin.dll"
```

NGFW 原版 SHA256 为
`a71b488ed31c038aae39863d47f253de8c7c46c2881f52d7868a83809defa14a`，22 站点
补丁版 SHA256 为
`8169f6169c86563f5ba8e2762cf579fad7eaab5374e76bb24bdce0d270641ec9`。
旧的 28 站点版本 `06966124…` 已弃用。

### 环境要求

- Python 3.x
- 插件是 32 位的；但补丁与架构无关（它只改字节），所以不需要任何工具链——
  有 Python 就行。
