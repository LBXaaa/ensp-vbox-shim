#!/usr/bin/env python3
"""Generate & verify the NGFW_Plugin.dll patch table from the live binary.

Only the disp32-form IVirtualBox *method* dispatches (5.2 slots 34-52) are
remapped -- the exact same method set the (SHA256-verified) VAR patch touches.
The 5.2->7.2 slot map below is copied from the verified VAR spec."""
import pefile, capstone, hashlib

HERE = __file__.rsplit("\\", 1)[0]
PATH = HERE + r"\NGFW_Plugin.dll"

# method -> (5.2 disp, 7.2 disp)  -- from verified var_plugin_ar1000v.md
REMAP = {
    "createSharedFolder":        (0x88, 0xCC),
    "createUnattendedInstaller": (0x8C, 0xB4),
    "findDHCPServerByNetworkName":(0x90, 0xE8),
    "findMachine":               (0x94, 0xA4),
    "findNATNetworkByName":      (0x98, 0xF4),
    "getExtraData":              (0x9C, 0xD8),
    "getExtraDataKeys":          (0xA0, 0xD4),
    "getGuestOSType":            (0xA4, 0xC0),
    "getMachineStates":          (0xA8, 0xAC),
    "getMachinesByGroups":       (0xAC, 0xA8),
    "openMachine":               (0xB0, 0x9C),
    "openMedium":                (0xB4, 0xBC),
    "registerMachine":           (0xB8, 0xA0),
    "removeDHCPServer":          (0xBC, 0xEC),
    "removeNATNetwork":          (0xC0, 0xF8),
    "removeSharedFolder":        (0xC4, 0xD0),
    "setExtraData":              (0xC8, 0xDC),
    "setSettingsSecret":         (0xCC, 0xE0),
    "checkFirmwarePresent":      (0xD0, 0x118),
}
DISP52_TO_NAME = {v[0]: k for k, v in REMAP.items()}

pe = pefile.PE(PATH, fast_load=True)
ib = pe.OPTIONAL_HEADER.ImageBase
sec = next(s for s in pe.sections if s.Name.rstrip(b"\x00") == b".text")
code, tva, traw = sec.get_data(), sec.VirtualAddress, sec.PointerToRawData
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32); md.detail = True

data = bytearray(open(PATH, "rb").read())
patch = []   # (file_off, pristine_byte, patched_byte, method)
for insn in md.disasm(code, ib + tva):
    if insn.mnemonic != "call" or len(insn.operands) != 1: continue
    op = insn.operands[0]
    if op.type != capstone.x86.X86_OP_MEM: continue
    m = op.mem
    if m.base == 0 or m.index != 0 or m.disp <= 0: continue
    b = insn.bytes
    if b[0] != 0xFF: continue
    modrm = b[1]
    if ((modrm >> 3) & 7) != 2: continue        # /2 = call
    mod = modrm >> 6
    if mod != 2: continue                        # only disp32 form (mod=10)
    disp = m.disp
    if disp not in DISP52_TO_NAME: continue
    name = DISP52_TO_NAME[disp]
    d52, d72 = REMAP[name]
    disp_off = (insn.address - (ib + tva)) + traw + 2   # disp32 starts at insn+2
    # low byte
    lo52, lo72 = d52 & 0xFF, d72 & 0xFF
    assert data[disp_off] == lo52, f"@0x{disp_off:X} exp {lo52:02X} got {data[disp_off]:02X}"
    patch.append((disp_off, lo52, lo72, name))
    # high byte only differs for checkFirmwarePresent (0x00D0 -> 0x0118)
    if (d52 >> 8) != (d72 >> 8):
        assert data[disp_off+1] == (d52 >> 8) & 0xFF
        patch.append((disp_off+1, (d52 >> 8) & 0xFF, (d72 >> 8) & 0xFF, name))

patch.sort()
print(f"# {len(patch)} bytes across {len({o for o,_,_,_ in patch})} offsets")
print("PATCH_TABLE = [")
for off, p, q, name in patch:
    print(f"    (0x{off:06X}, 0x{p:02X}, 0x{q:02X}, \"{name}\"),")
print("]")

# compute pristine + patched whole-file sha256
print(f"\nsha256 pristine: {hashlib.sha256(bytes(data)).hexdigest()}")
for off, p, q, name in patch:
    data[off] = q
print(f"sha256 patched : {hashlib.sha256(bytes(data)).hexdigest()}")
print(f"size           : {len(data)}")
