# analysis/

The reverse-engineering work that produced the vtable mapping and the calling
contract the shim implements. These are **provenance** — you don't need to run
them to use the shim, but they show *how* the layout in
[`docs/vtable-mapping.md`](../docs/vtable-mapping.md) was derived, and why the
proxy is shaped the way it is.

## output/

| file | what it establishes |
|------|---------------------|
| `vbox728_vtable.md` | The full VBox **7.2.8** `IVirtualBox` vtable, parsed from the type library embedded in `VBoxProxyStub.dll` via `comtypes`. Confirms the `IDispatch` +4 base and the 92-entry layout — the destination side of every forward. |
| `ensp_calling_analysis.md` | How eNSP actually calls the proxy: direct numeric-offset vtable dispatch (not `IDispatch`), `call reg` (not `call [reg+off]`), STA `CoInitialize`, HRESULT-style return checks. This is why the proxy is a flat vtable and why slot [1]'s exact stack shape mattered. |

## scripts/

Python reverse-engineering tools (Capstone + pefile + comtypes). They read the
*installed* eNSP and VirtualBox binaries on your machine — they embed no
copyrighted bytes themselves. Paths inside are hardcoded to the standard install
locations; edit them if yours differ.

| script | purpose |
|--------|---------|
| `analyze_vtable.py` | parse the 7.2 typelib → vtable table |
| `analyze_vbox52.py`, `disasm_vbox52.py` | disassemble the original Huawei `VBox52.dll` |
| `analyze_ensp_calling.py`, `extract_calling_details.py` | recover eNSP's call sites and convention |
| `find_vtable_calls_final.py`, `trace_proxy_usage.py` | locate vtable dispatch sites against the proxy |
| `dump_string_params.py`, `find_path_code.py` | trace BSTR/path arguments |
| `deep_context_analysis.py`, `final_comprehensive.py` | consolidated passes |

> These are research scripts, kept as-is for the record. They are not part of the
> build and are not maintained as a polished tool.
