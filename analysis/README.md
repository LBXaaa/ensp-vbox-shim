# analysis/

产出 vtable 映射、以及垫片所实现的调用契约的那部分逆向工作。这些是**出处
留档**——用垫片并不需要跑它们，但它们展示了
[`docs/vtable-mapping.md`](../docs/vtable-mapping.md) 里那套布局是*怎么*推导出来
的，以及代理为什么长成这个样子。

## output/

| 文件 | 它确立了什么 |
|------|--------------|
| `vbox728_vtable.md` | 完整的 VBox **7.2.8** `IVirtualBox` vtable，通过 `comtypes` 从 `VBoxProxyStub.dll` 内嵌的类型库解析而来。确认了 `IDispatch` +4 的基址和 92 项的布局——也就是每一次转发的目的地一侧。 |
| `ensp_calling_analysis.md` | eNSP 实际是怎么调用代理的：直接按数字偏移做 vtable 分派（不走 `IDispatch`）、`call reg`（而非 `call [reg+off]`）、STA 的 `CoInitialize`、HRESULT 风格的返回值检查。这就是为什么代理是一张扁平 vtable，以及为什么槽位 [1] 那精确的栈形态至关重要。 |

## scripts/

Python 逆向工具（Capstone + pefile + comtypes）。它们读取你机器上*已安装*的
eNSP 和 VirtualBox 二进制——本身不内嵌任何受版权保护的字节。脚本里的路径写死
成了标准安装位置；你的若不同，自行修改。

| 脚本 | 用途 |
|------|------|
| `analyze_vtable.py` | 解析 7.2 类型库 → vtable 表 |
| `analyze_vbox52.py`、`disasm_vbox52.py` | 反汇编华为原版 `VBox52.dll` |
| `analyze_ensp_calling.py`、`extract_calling_details.py` | 还原 eNSP 的调用站点与调用约定 |
| `find_vtable_calls_final.py`、`trace_proxy_usage.py` | 定位针对代理的 vtable 分派站点 |
| `dump_string_params.py`、`find_path_code.py` | 追踪 BSTR/路径参数 |
| `deep_context_analysis.py`、`final_comprehensive.py` | 合并后的综合分析 |

> 这些是研究脚本，原样保留作为记录。它们不属于构建流程，也不作为打磨过的工具
> 来维护。
