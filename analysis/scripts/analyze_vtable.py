#!/usr/bin/env python3
"""
VBox52.dll vtable 分析：
找出代码中所有通过 vtable 调用 IVirtualBox 方法的位置，
记录每个调用的 vtable 偏移，用于比对 VBox 5.2 vs 7.x 的兼容性。
"""
import struct
from capstone import *
from capstone.x86 import *
import os

DLL_PATH = r"C:\Program Files\Huawei\eNSP\tools\VBox52.dll"
IAT_SIGS = {
    # Known IAT entries we're looking for
    b'\xe0\x13\x02\x10': 'CoCreateInstance',
    b'\x3c\x12\x02\x10': None,  # Another IAT entry
    b'\x2c\x12\x02\x10': None,  # Sleep/retry
}

with open(DLL_PATH, 'rb') as f:
    data = f.read()

# Parse PE
pe_off = struct.unpack_from('<I', data, 0x3C)[0]
num_sects = struct.unpack_from('<H', data, pe_off+6)[0]
sect_hdr_start = pe_off + 24 + 248  # PE32

sections = {}
for i in range(num_sects):
    s = sect_hdr_start + i * 40
    name = data[s:s+8].split(b'\x00')[0].decode()
    v_addr = struct.unpack_from('<I', data, s+12)[0]
    v_size = struct.unpack_from('<I', data, s+8)[0]
    r_addr = struct.unpack_from('<I', data, s+20)[0]
    sections[name] = (v_addr, v_size, r_addr)

def rva2off(rva):
    for name, (va, vs, ro) in sections.items():
        if va <= rva < va + vs:
            return ro + (rva - va)
    return None

def off2va(offset, section_name='.text'):
    va, vs, ro = sections[section_name]
    return 0x10000000 + va + (offset - ro)

# Build IAT map: for each call [address] pattern, identify the API name
iat_map = {}
import_sections = [n for n in sections if n.startswith('.idata')]
for isec in import_sections:
    iva, ivs, iro = sections[isec]
    iat_data = data[iro:iro+ivs]

    # Parse IAT thunks to find API addresses
    # IAT entries are array of RVAs pointing to the import name strings
    for off in range(0, len(iat_data) - 4, 4):
        iat_rva = struct.unpack_from('<I', iat_data, off)[0]
        if iat_rva == 0:
            break
        if iat_rva & 0x80000000:  # Ordinal import (MSB set)
            continue

        name_off = rva2off(iat_rva)
        if name_off:
            # Skip bound import names (they start with hint/ordinal word)
            hint = struct.unpack_from('<H', data, name_off)[0]
            null_pos = data.index(b'\x00', name_off + 2)
            api_name = data[name_off+2:null_pos].decode('ascii', errors='replace')
            iat_va = 0x10000000 + iva + off
            iat_map[iat_va] = api_name

print(f"Found {len(iat_map)} IAT entries")
for va, name in sorted(iat_map.items(), key=lambda x: x[0]):
    if 'VBox' in name or 'CoCreate' in name or 'Instance' in name or 'Initialize' in name or 'Variant' in name or 'Safe' in name or 'Sys' in name or 'Reg' in name:
        print(f"  IAT 0x{va:08X}: {name}")

# Disassemble .text section and find ALL calls
va_text, vs_text, ro_text = sections['.text']
code = data[ro_text:ro_text+vs_text]
BASE = 0x10000000

md = Cs(CS_ARCH_X86, CS_MODE_32)
md.detail = True

print(f"\n{'='*80}")
print("CODE FLOW ANALYSIS")
print(f"{'='*80}")

# Track all vtable call sites
vtable_calls = []  # (address, base_reg, offset, context_instrs)

# Track CoCreateInstance parameters
cocreate_calls = []

# Also track the Known export functions
exports = {}
exp_rva = struct.unpack_from('<I', data, struct.unpack_from('<I', data, pe_off+24+96)[0], 4)[0]
if exp_rva:
    eo = rva2off(exp_rva)
    if eo:
        num_names = struct.unpack_from('<I', data, eo+24)[0]
        name_arr_off = rva2off(struct.unpack_from('<I', data, eo+32)[0])
        ord_arr_off = rva2off(struct.unpack_from('<I', data, eo+36)[0])
        fn_arr_off = rva2off(struct.unpack_from('<I', data, eo+28)[0])
        for i in range(num_names):
            nrv = struct.unpack_from('<I', data, name_arr_off + i*4)[0]
            no = rva2off(nrv)
            ord_ = struct.unpack_from('<H', data, ord_arr_off + i*2)[0]
            fn_rva = struct.unpack_from('<I', data, fn_arr_off + ord_*4)[0]
            name = data[no:data.index(b'\x00', no)].decode()
            exports[name] = 0x10000000 + fn_rva

print(f"Export functions: {list(exports.keys())}")

# Now disassemble the whole .text section, function by function
# First, let's find function boundaries by following from exports
disasm_start = 0x10000000

# Disassemble the whole section in one pass
all_instrs = list(md.disasm(code, disasm_start))
print(f"Total instructions: {len(all_instrs)}")

# Analyze each instruction
for insn in all_instrs:
    mnem = insn.mnemonic
    op_str = insn.op_str

    # Classify the instruction
    if mnem in ('call', 'jmp'):
        # Direct call (call 0x12345678)
        if insn.operands and insn.operands[0].type == X86_OP_IMM:
            target = insn.operands[0].imm
            # Check for IAT call: call dword ptr [address]
            pass

        # Indirect call through memory: call dword ptr [reg+offset]
        elif '[' in op_str:
            for op in insn.operands:
                if op.type == X86_OP_MEM and op.mem.base != 0:
                    base_reg = insn.reg_name(op.mem.base)
                    disp = op.mem.disp
                    if base_reg in ('eax', 'ecx', 'edx', 'ebx', 'esi', 'edi') and disp > 0:
                        # Get context (previous 5 instructions)
                        vtable_calls.append((insn.address, base_reg, disp))

        # Indirect call through register: call eax
        elif op_str in ('eax', 'ecx', 'edx', 'ebx', 'esi', 'edi'):
            vtable_calls.append((insn.address, op_str, -1))  # -1 means register call (no offset)

print(f"\n=== VTABLE CALL SITES FOUND: {len(vtable_calls)} ===")

# Group by offset for analysis
from collections import Counter
offset_counts = Counter([d for _, _, d, *_ in vtable_calls if d >= 0])
if offset_counts:
    print(f"\nVtable offsets used (sorted by offset):")
    for offset in sorted(offset_counts.keys()):
        count = offset_counts[offset]
        # COM vtable offset 0 = QueryInterface, 4 = AddRef, 8 = Release
        # Then methods start at offset 12 (index 3) for IUnknown-derived, or later for IDispatch
        method_index = offset // 4
        base_class = ""
        if method_index < 3:
            base_class = " [IUnknown: QI/AddRef/Release]"
        elif method_index == 3:
            base_class = " [IDispatch: GetTypeInfoCount]"
        elif method_index == 4:
            base_class = " [IDispatch: GetTypeInfo]"
        elif method_index == 5:
            base_class = " [IDispatch: GetIDsOfNames]"
        elif method_index == 6:
            base_class = " [IDispatch: Invoke]"

        print(f"  vtable+0x{offset:03X} (index {method_index}): called {count} times{base_class}")

    print(f"\n  Total unique vtable offsets: {len(offset_counts)}")

# Print each vtable call with its surrounding code
print(f"\n{'='*80}")
print("DETAILED VTABLE CALL SITES")
print(f"{'='*80}")

for addr, base_reg, disp in sorted(set(vtable_calls), key=lambda x: x[0]):
    print(f"\n--- 0x{addr:08X}: call [{base_reg}", end="")
    if disp >= 0:
        print(f"+0x{disp:X}] (offset 0x{disp:03X}, method index {disp//4})", end="")
    print(" ---")

    # Print 8 instructions before this one
    idx = all_instrs.index(insn) if (insn := next((i for i in all_instrs if i.address == addr), None)) else -1
    if idx > 0:
        for j in range(max(0, idx-8), idx):
            i = all_instrs[j]
            print(f"       0x{i.address:08X}: {i.mnemonic:8s} {i.op_str}")

# Now specifically analyze the CoCreateInstance calling function
print(f"\n{'='*80}")
print("COCREATEINSTANCE CALLER ANALYSIS")
print(f"{'='*80}")

# We know CoCreateInstance IAT is at 0x100213E0
# Find the function that loads it
for i, insn in enumerate(all_instrs):
    if insn.mnemonic == 'mov' and '[0x100213E0]' in insn.op_str:
        # Found the function that sets up CoCreateInstance call
        print(f"\nFunction loading CoCreateInstance @ 0x{insn.address:08X}:")
        # Print surrounding code
        for j in range(max(0, i-2), min(len(all_instrs), i+30)):
            ii = all_instrs[j]
            print(f"  0x{ii.address:08X}: {ii.mnemonic:8s} {ii.op_str}")
            if ii.mnemonic == 'ret':
                break

# Analyze: does eNSP use IVirtualBox through IDispatch or direct vtable?
print(f"\n{'='*80}")
print("IDispatch vs COM ANALYSIS")
print(f"{'='*80}")

# Check for IDispatch methods: GetIDsOfNames, Invoke
has_idispatch = False
for insn in all_instrs:
    iat_api = iat_map.get(insn.address, '')
    if 'GetIDsOfNames' in iat_api or 'Invoke' in iat_api:
        has_idispatch = True
        print(f"  IDispatch usage: {iat_api} @ 0x{insn.address:08X}")

if not has_idispatch:
    print("  No IDispatch calls found - using direct vtable dispatch")

# Check for IUnknown methods: QueryInterface, AddRef, Release
for insn in all_instrs:
    iat_api = iat_map.get(insn.address, '')
    if 'QueryInterface' in iat_api:
        print(f"  QueryInterface @ 0x{insn.address:08X}")

print(f"\n{'='*80}")
print("CALL SITES BY FUNCTION (LIKELY IVirtualBox METHODS USED)")
print(f"{'='*80}")

# For each unique vtable offset, figure out what the caller function does
# by looking at context
for offset in sorted(offset_counts.keys()):
    count = offset_counts[offset]
    method_idx = offset // 4
    print(f"\n  vtable+0x{offset:03X} (method[{method_idx}]): {count} call(s)")

    # Find an example call site for this offset
    for addr, base_reg, disp in vtable_calls:
        if disp == offset:
            # Print context
            insn = next(i for i in all_instrs if i.address == addr)
            idx = all_instrs.index(insn)
            print(f"    Example @ 0x{addr:08X}:")
            for j in range(max(0, idx-5), idx):
                print(f"      0x{all_instrs[j].address:08X}: {all_instrs[j].mnemonic:8s} {all_instrs[j].op_str}")
            print(f"  -> 0x{addr:08X}: {insn.mnemonic:8s} {insn.op_str}")
            break

print(f"\n{'='*80}")
print("ANALYSIS COMPLETE")
print(f"{'='*80}")
