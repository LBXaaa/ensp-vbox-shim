# patches/

Binary patches applied to **Huawei eNSP** files so they cooperate with
VirtualBox 7.x. These scripts edit your *own* installed copies in place; this
repo ships **no** Huawei or Oracle binaries.

## Files

| file | purpose |
|------|---------|
| `patch_var_plugin.py`   | applies / restores the VAR_Plugin.dll vtable remap |
| `var_plugin_ar1000v.md` | full spec: the 28 call sites, slot derivation, instruction shape |

## VAR_Plugin.dll (ar1000v)

The AR router plugin calls a real 7.2 `IVirtualBox` through hard-coded **5.2**
vtable offsets. On 7.x those offsets hit the wrong methods and AR crashes on
start. The patch rewrites 28 dispatch sites (29 bytes) to the correct 7.2 slots.
It changes only `call [reg+disp]` displacement bytes — the file size is
unchanged and the edit is fully reversible.

```bat
:: inspect (read-only)
python patch_var_plugin.py --check   "C:\Program Files\Huawei\eNSP\plugin\ar1000v\VAR_Plugin.dll"

:: patch (writes a .bak next to the dll first)
python patch_var_plugin.py           "C:\Program Files\Huawei\eNSP\plugin\ar1000v\VAR_Plugin.dll"

:: revert
python patch_var_plugin.py --restore "C:\Program Files\Huawei\eNSP\plugin\ar1000v\VAR_Plugin.dll"
```

### Safety guarantees

- The patcher only accepts the **2019 factory build** (size 393216, pristine
  SHA256 `5ae6817a…`). Anything else is refused.
- Before writing, every target byte is checked to hold its expected pre-patch
  value (defense in depth on top of the whole-file hash).
- After writing, the result is re-hashed and must equal the known patched
  SHA256 (`f0107975…`), or the file is not saved.
- A `.bak` copy is made unless you pass `--no-backup`.

### Requirements

- Python 3.x
- The plugin is 32-bit; the patch is architecture-agnostic (it edits bytes), so
  no toolchain is needed — just Python.
