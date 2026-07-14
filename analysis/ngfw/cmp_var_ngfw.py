#!/usr/bin/env python3
"""Compare IVirtualBox-shaped call sites between VAR_Plugin.orig.dll (proven,
patched successfully for AR) and NGFW_Plugin.dll (crashes). For every
`call [reg+disp]` whose disp lands in the 5.2 method range, classify the
RECEIVER source by looking at the 1-3 insns immediately before:

  SINGLETON : preceded by `call <accessor>; mov eax,[eax+4]; mov edx,[eax]`
              (the realVBox singleton pattern -> genuine IVirtualBox)
  THIS/MEMBER: `mov eax,[esi]` / `mov eax,[esi+XX]` / `mov edx,[ecx..]`
              (receiver is `this` or a member obj -> possibly NGFW-own class)
  RETVAL    : `mov edx,[eax]` where eax is a prior call's return value
  OTHER

Prints side-by-side counts so we can see if NGFW patches disp values that VAR
never touches on non-IVirtualBox receivers."""
import pefile, capstone
from collections import defaultdict

HERE = __file__.rsplit("\\",1)[0]
TARGETS = {"VAR.orig": HERE+r"\VAR_Plugin.orig.dll",
           "NGFW":     HERE+r"\NGFW_Plugin.dll"}

# 5.2 method disps the patch cares about (0x88..0xD0) plus a bit of range
LO, HI = 0x0C, 0xD4     # slot 3..53 -> disp 0x0C..0xD4
NAME52 = {0x88:"createSharedFolder",0x8C:"createUnattended",0x90:"findDHCPByName",
0x94:"findMachine",0x98:"findNATByName",0x9C:"getExtraData",0xA0:"getExtraDataKeys",
0xA4:"getGuestOSType",0xA8:"getMachineStates",0xAC:"getMachinesByGroups",
0xB0:"openMachine",0xB4:"openMedium",0xB8:"registerMachine",0xBC:"removeDHCPServer",
0xC0:"removeNATNetwork",0xC4:"removeSharedFolder",0xC8:"setExtraData",
0xCC:"setSettingsSecret",0xD0:"checkFirmwarePresent"}

def classify(insns, idx):
    # look back a few insns
    prev = [insns[j] for j in range(max(0,idx-4), idx)]
    txt = " ; ".join(f"{i.mnemonic} {i.op_str}" for i in prev)
    # singleton: a call then [eax+4] then [eax]
    has_call = any(i.mnemonic=="call" and i.op_str.startswith("0x") for i in prev)
    if has_call and "[eax + 4]" in txt and "dword ptr [eax]" in txt:
        return "SINGLETON", txt
    # this/member
    if "[esi]" in txt or "[esi +" in txt or "[edi]" in txt or "[edi +" in txt:
        return "THIS/MEMBER", txt
    if "[ecx]" in txt or "[ecx +" in txt:
        return "THIS/MEMBER", txt
    return "OTHER", txt

for label, path in TARGETS.items():
    pe = pefile.PE(path, fast_load=True)
    ib = pe.OPTIONAL_HEADER.ImageBase
    sec = next(s for s in pe.sections if s.Name.rstrip(b"\x00")==b".text")
    code, tva = sec.get_data(), sec.VirtualAddress
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32); md.detail=True
    insns = list(md.disasm(code, ib+tva))
    buckets = defaultdict(lambda: defaultdict(int))
    detail = defaultdict(list)
    for idx,i in enumerate(insns):
        if i.mnemonic!="call" or len(i.operands)!=1: continue
        op=i.operands[0]
        if op.type!=capstone.x86.X86_OP_MEM: continue
        m=op.mem
        if m.base==0 or m.index!=0: continue
        b=i.bytes
        if b[0]!=0xFF or ((b[1]>>3)&7)!=2 or (b[1]>>6)!=2: continue  # call /2 disp32
        disp=m.disp
        if disp not in NAME52: continue
        cls,ctx = classify(insns, idx)
        buckets[disp][cls]+=1
        detail[disp].append((cls, i.address, ctx))
    print(f"\n########## {label} ##########")
    for disp in sorted(buckets):
        parts=" ".join(f"{k}={v}" for k,v in buckets[disp].items())
        print(f"  disp 0x{disp:02X} {NAME52[disp]:22} : {parts}")
    # show THIS/MEMBER ones (误伤嫌疑) in detail
    print(f"  --- THIS/MEMBER receivers (误伤嫌疑) ---")
    for disp in sorted(detail):
        for cls,addr,ctx in detail[disp]:
            if cls=="THIS/MEMBER":
                print(f"    0x{disp:02X} {NAME52[disp]:20} @{addr:08X}  <- {ctx}")
