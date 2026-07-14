#!/usr/bin/env python3
"""Derive the NGFW_Plugin.dll IVirtualBox 5.2->7.2 vtable remap table.

Strategy (same as VAR): the plugin holds a real IVirtualBox* and dispatches
through it with `call [reg+disp]` where disp/4 is a hard-coded 5.2 vtable slot.
On 7.2 those slots moved. We find every such dispatch whose disp/4 lands in the
5.2 IVirtualBox method range and emit a patch that rewrites disp to the 7.2 slot.

We can't blindly trust *every* `call [reg+disp]` -- reg could be any object, not
just IVirtualBox. So we disassemble the whole .text, collect candidate sites,
and print them grouped by 5.2 slot so a human can confirm against the known
method set the plugin actually uses (the VAR spec lists the AR subset).
"""
import pefile
import capstone

HERE = __file__.rsplit("\\", 1)[0]
PATH = HERE + r"\NGFW_Plugin.dll"

# ---- 5.2 IVirtualBox slot -> method name (from CLAUDE.md). idx 0..48 ----
V52 = {
    0:"QueryInterface",1:"AddRef/cloneProbe",2:"Release",
    3:"get_version",4:"get_versionNormalized",5:"get_revision",6:"get_packageType",
    7:"get_APIVersion",8:"get_APIRevision",9:"get_homeFolder",10:"get_settingsFilePath",
    11:"get_host",12:"get_systemProperties",13:"get_machines",14:"get_machineGroups",
    15:"get_hardDisks",16:"get_DVDImages",17:"get_floppyImages",18:"get_progressOperations",
    19:"get_guestOSTypes",20:"get_sharedFolders",21:"get_performanceCollector",
    22:"get_DHCPServers",23:"get_NATNetworks",24:"get_eventSource",25:"get_extensionPackManager",
    26:"get_internalNetworks",27:"get_genericNetworkDrivers",28:"composeMachineFilename",
    29:"createAppliance",30:"createDHCPServer",31:"createMachine",32:"createMedium",
    33:"createNATNetwork",34:"createSharedFolder",35:"createUnattendedInstaller",
    36:"findDHCPServerByNetworkName",37:"findMachine",38:"findNATNetworkByName",
    39:"getExtraData",40:"getExtraDataKeys",41:"getGuestOSType",42:"getMachineStates",
    43:"getMachinesByGroups",44:"openMachine",45:"openMedium",46:"registerMachine",
    47:"removeDHCPServer",48:"removeNATNetwork",49:"removeSharedFolder",
    50:"setExtraData",51:"setSettingsSecret",52:"checkFirmwarePresent",
}
# ---- method name -> 7.2 slot (from CLAUDE.md / vtable-mapping.md) ----
V72 = {
    "QueryInterface":0,"Release":2,
    "get_version":7,"get_versionNormalized":8,"get_revision":9,"get_packageType":10,
    "get_APIVersion":11,"get_APIRevision":12,"get_homeFolder":13,"get_settingsFilePath":14,
    "get_host":15,"get_systemProperties":16,"get_machines":17,"get_machineGroups":18,
    "get_hardDisks":19,"get_DVDImages":20,"get_floppyImages":21,"get_progressOperations":22,
    "get_guestOSTypes":23,"get_sharedFolders":25,"get_performanceCollector":26,
    "get_DHCPServers":27,"get_NATNetworks":28,"get_eventSource":29,"get_extensionPackManager":30,
    "get_internalNetworks":31,"get_genericNetworkDrivers":33,"composeMachineFilename":36,
    "createAppliance":44,"createDHCPServer":57,"createMachine":38,"createMedium":46,
    "createNATNetwork":60,"createSharedFolder":51,"createUnattendedInstaller":45,
    "findDHCPServerByNetworkName":58,"findMachine":41,"findNATNetworkByName":61,
    "getExtraData":54,"getExtraDataKeys":53,"getGuestOSType":48,"getMachineStates":43,
    "getMachinesByGroups":42,"openMachine":39,"openMedium":47,"registerMachine":40,
    "removeDHCPServer":59,"removeNATNetwork":62,"removeSharedFolder":52,
    "setExtraData":55,"setSettingsSecret":56,"checkFirmwarePresent":70,
}

pe = pefile.PE(PATH, fast_load=True)
image_base = pe.OPTIONAL_HEADER.ImageBase
text = None
for s in pe.sections:
    nm = s.Name.rstrip(b"\x00").decode(errors="replace")
    if nm == ".text":
        text = s
        break
assert text, "no .text"
code = text.get_data()
text_va = text.VirtualAddress
text_raw = text.PointerToRawData
print(f"image_base=0x{image_base:X} .text VA=0x{text_va:X} raw=0x{text_raw:X} size=0x{len(code):X}")

md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
md.detail = True

# Scan for FF /2 (call r/m) with a register base + disp32 or disp8.
sites = []  # (file_off_of_disp, disp, slot, reg)
for insn in md.disasm(code, image_base + text_va):
    if insn.mnemonic != "call":
        continue
    if len(insn.operands) != 1:
        continue
    op = insn.operands[0]
    if op.type != capstone.x86.X86_OP_MEM:
        continue
    m = op.mem
    if m.base == 0 or m.index != 0:
        continue          # need [reg+disp], no SIB
    disp = m.disp
    if disp <= 0 or disp % 4 != 0:
        continue
    slot = disp // 4
    if slot < 3 or slot > 52:
        continue          # only IVirtualBox method-ish range
    # find file offset of the displacement bytes within this insn
    # insn.bytes: [FF] [modrm] [disp...]. modrm reg field=010 (call /2).
    b = insn.bytes
    # locate modrm
    idx = 0
    # skip prefixes (none expected here for FF /2 on r32)
    if b[0] != 0xFF:
        continue
    modrm = b[1]
    reg = (modrm >> 3) & 7
    if reg != 2:
        continue          # /2 = call
    mod = modrm >> 6
    rm = modrm & 7
    disp_field_start = 2
    if rm == 4:           # SIB present
        disp_field_start = 3
    va = insn.address
    file_off = (va - (image_base + text_va)) + text_raw + disp_field_start
    reg_name = insn.op_str
    sites.append((file_off, disp, slot, insn.address, reg_name, b.hex()))

print(f"\n{len(sites)} candidate IVirtualBox-shaped dispatch sites\n")
from collections import defaultdict
bybucket = defaultdict(list)
for fo, disp, slot, va, reg, hx in sites:
    bybucket[slot].append((fo, disp, va, reg, hx))
for slot in sorted(bybucket):
    name = V52.get(slot, "?")
    tgt = V72.get(name)
    tgt_disp = tgt*4 if tgt is not None else None
    print(f"5.2 slot {slot} (disp 0x{slot*4:X}) = {name}  -> 7.2 slot {tgt} (disp 0x{tgt_disp:X})" if tgt is not None else f"5.2 slot {slot} (disp 0x{slot*4:X}) = {name}  -> (no 7.2 map)")
    for fo, disp, va, reg, hx in bybucket[slot]:
        print(f"    @file 0x{fo:06X}  va 0x{va:X}  disp 0x{disp:X}  [{reg}]  {hx}")
