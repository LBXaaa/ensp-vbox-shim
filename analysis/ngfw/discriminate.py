#!/usr/bin/env python3
"""For each of the 29 patch sites, disassemble a window and heuristically decide
whether the `call [reg+disp]` receiver is the real IVirtualBox (came from
GetVBoxInstance / a global realVBox pointer) or an NGFW-own C++ object (new'd
locally, vtable inside ngfw module).

Heuristic per site: walk back up to ~40 insns from the call, track how the
base register got its object pointer. Flag markers:
  - object from `call` to a small allocator then vtable store of 0x1004xxxx  -> NGFW-own
  - object from a global [0x1005xxxx]/[0x1002xxxx] singleton              -> ambiguous
  - object passed in as `this` (ecx on entry) / from IVirtualBox getter    -> likely IVBox
This is advisory; prints context for human confirmation."""
import pefile, capstone

HERE = __file__.rsplit("\\",1)[0]
PATH = HERE + r"\NGFW_Plugin.dll"          # patched
ORIG = HERE + r"\VAR_Plugin.orig.dll"      # not used here, ref only

# the 29 patch offsets (file offsets of the disp byte) from patch_ngfw_plugin.py
SITES = [0x0168CE,0x0168E3,0x0172BA,0x01754C,0x0177DC,0x017F03,0x01BF3A,
0x01ED53,0x01EDA1,0x01EDFB,0x01EE55,0x01EEAF,0x01EF09,0x01EF63,0x01EFBD,
0x01F017,0x01F074,0x01F0CE,0x01F11C,0x01F16A,0x01F1C4,0x01F21E,0x01F281,
0x01F2DE,0x01F332,0x01FEA1,0x021700,0x022002]

pe = pefile.PE(PATH, fast_load=True)
ib = pe.OPTIONAL_HEADER.ImageBase
sec = next(s for s in pe.sections if s.Name.rstrip(b"\x00")==b".text")
code, tva, traw = sec.get_data(), sec.VirtualAddress, sec.PointerToRawData
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32); md.detail=True

def va_of_disp_fileoff(fo):
    # disp byte is at insn+2 (FF modrm disp32). so insn VA = ib+tva+(fo-2-traw)
    return ib + tva + (fo - 2 - traw)

# disassemble whole .text into addr-indexed list for back-walking
insns = list(md.disasm(code, ib+tva))
by_addr = {i.address: idx for idx,i in enumerate(insns)}

for fo in SITES:
    call_va = va_of_disp_fileoff(fo)
    idx = by_addr.get(call_va)
    print(f"\n===== site file 0x{fo:06X}  callVA 0x{call_va:X} =====")
    if idx is None:
        print("  (no aligned insn — disp inside another insn?)")
        continue
    lo = max(0, idx-14)
    for j in range(lo, idx+1):
        i = insns[j]
        mark = " <== CALL" if j==idx else ""
        print(f"  {i.address:08X}  {i.mnemonic:6} {i.op_str}{mark}")
