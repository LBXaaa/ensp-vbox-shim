#!/usr/bin/env python3
"""Capstone-based full disassembly and analysis of VBox52.dll"""

import struct
from capstone import *
from capstone.x86 import *
import os

DLL_PATH = r"C:\Program Files\Huawei\eNSP\tools\VBox52.dll"
OUTPUT_DIR = r"F:\各种项目\逆向ensp\analysis\output"

os.makedirs(OUTPUT_DIR, exist_ok=True)

with open(DLL_PATH, 'rb') as f:
    data = f.read()

# Parse PE headers
def read_le(offset, size):
    return int.from_bytes(data[offset:offset+size], 'little')

pe_offset = read_le(0x3C, 4)
assert data[pe_offset:pe_offset+4] == b'PE\x00\x00', "Not a PE file"

machine = read_le(pe_offset+4, 2)
num_sects = read_le(pe_offset+6, 2)
opt_hdr_size = read_le(pe_offset+20, 2)
opt_hdr_start = pe_offset + 24
magic = read_le(opt_hdr_start, 2)

print(f"Machine: {'x86' if machine == 0x14c else 'x64'}")
print(f"Sections: {num_sects}")

# Parse sections
sect_hdr_start = opt_hdr_start + (248 if magic == 0x10b else 264)
sections = []
for i in range(num_sects):
    s_start = sect_hdr_start + i * 40
    name = data[s_start:s_start+8].rstrip(b'\x00').decode('ascii', errors='replace')
    v_size = read_le(s_start+8, 4)
    v_addr = read_le(s_start+12, 4)
    r_size = read_le(s_start+16, 4)
    r_addr = read_le(s_start+20, 4)
    sections.append((name, v_addr, v_size, r_addr, r_size))
    print(f"  {name}: VA=0x{v_addr:08X} VSz=0x{v_size:X} FO=0x{r_addr:08X} RSz=0x{r_size:X}")

def rva_to_offset(rva):
    for name, v_addr, v_size, r_addr, r_size in sections:
        if v_addr <= rva < v_addr + v_size:
            return r_addr + (rva - v_addr)
    return None

# Parse export table
data_dir_start = opt_hdr_start + 96 if magic == 0x10b else opt_hdr_start + 112
export_rva = read_le(data_dir_start, 4)
export_size = read_le(data_dir_start+8, 4)

if export_size:
    exp_off = rva_to_offset(export_rva)
    num_fns = read_le(exp_off+20, 4)
    num_names = read_le(exp_off+24, 4)
    addr_fns_off = rva_to_offset(read_le(exp_off+28, 4))
    addr_names_off = rva_to_offset(read_le(exp_off+32, 4))
    addr_ord_off = rva_to_offset(read_le(exp_off+36, 4))

    print("\n=== Exports ===")
    exports = {}
    for i in range(num_names):
        name_rva = read_le(addr_names_off + i*4, 4)
        name_off = rva_to_offset(name_rva)
        ordinal = read_le(addr_ord_off + i*2, 2)
        fn_rva = read_le(addr_fns_off + ordinal*4, 4)
        name = data[name_off:data.index(b'\x00', name_off)].decode('ascii', errors='replace')
        exports[name] = fn_rva
        print(f"  [{ordinal}] {name} @ RVA 0x{fn_rva:08X}")

# Disassemble .text section
for sec_name, v_addr, v_size, r_addr, r_size in sections:
    if sec_name == '.text':
        code = data[r_addr:r_addr+r_size]
        base_addr = 0x10000000  # Image base
        md = Cs(CS_ARCH_X86, CS_MODE_32)
        md.detail = True

        # Organize into functions (based on exports and known patterns)
        functions = {}

        # Start disassembly from each export point
        for func_name, func_rva in exports.items():
            func_va = base_addr + func_rva
            func_offset = func_rva - v_addr  # relative to .text section start

            if func_offset < 0 or func_offset > r_size:
                print(f"\n[!] {func_name} @ RVA 0x{func_rva:08X} outside .text section")
                continue

            # Disassemble function
            func_code = code[func_offset:]
            print(f"\n{'='*60}")
            print(f"== Function: {func_name} @ VA 0x{func_va:08X} (FO: 0x{r_addr + func_offset:08X}) ==")
            print(f"{'='*60}")

            instructions = []
            for insn in md.disasm(func_code, func_va):
                if len(instructions) > 500:  # Safety limit
                    break
                instructions.append(insn)

                # Print instruction with analysis
                op_str = insn.op_str

                # Highlight CALL instructions
                prefix = ""
                if insn.mnemonic == "call":
                    if insn.operands[0].type == X86_OP_IMM:
                        target = insn.operands[0].imm
                        # Check if it's a known function
                        for ename, erva in exports.items():
                            if target == base_addr + erva:
                                prefix = f"[-> {ename}]"
                                break
                        # Check if it's an IAT call
                        target_off = rva_to_offset(target - base_addr)
                        if target_off:
                            # Try to read string near IAT
                            iat_str = data[target_off:target_off+32]
                            printable = ''.join(chr(b) if 32 <= b < 127 else '.' for b in iat_str)
                            api_name = printable.split('\x00')[0] if '\x00' in printable else printable[:20]
                            prefix = f"[IAT: {api_name}]"

                elif insn.mnemonic.startswith("j") and insn.operands[0].type == X86_OP_IMM:
                    # Jump to local target
                    pass

                # Print
                print(f"  0x{insn.address:08X}: {insn.mnemonic:8s} {op_str:30s} {prefix}")

                # Stop at RET if we seem to have completed the function
                if insn.mnemonic in ("ret", "retf"):
                    # Check if next bytes look like a new function (aligned padding)
                    next_offset = insn.address - func_va + insn.size
                    if next_offset + 4 < len(func_code):
                        remaining = func_code[next_offset:next_offset+8]
                        if all(b == 0xCC or b == 0x90 for b in remaining) or remaining[0] in (0x55, 0xE9, 0xEB):
                            break

            functions[func_name] = instructions
            print(f"  ({len(instructions)} instructions)")

        break

# Find and analyze the IVBoxInterface vtable
print("\n" + "="*60)
print("== Searching for IVBoxInterface vtable ==")
print("="*60)

# The RTTI string "?AUIVBoxInterface@@" is a struct
search = b"?AUIVBoxInterface@@"
idx = data.find(search)
if idx >= 0:
    print(f"  Found IVBoxInterface RTTI at FO: 0x{idx:08X}")
    # The RTTI locator might be nearby - print context
    ctx = data[max(0,idx-32):idx+64]
    print("  Context:", ' '.join(f'{b:02x}' for b in ctx))

# Also search for CVBox rtti
search2 = b".?AVCVBox@@"
idx2 = data.find(search2)
if idx2 >= 0:
    print(f"  Found CVBox RTTI at FO: 0x{idx2:08X}")
    ctx = data[max(0,idx2-32):idx2+64]
    print("  Context:", ' '.join(f'{b:02x}' for b in ctx))

# Search for any vtable references - look for RTTI Complete Object Locators
# In MSVC, vtables have a specific pattern
print("\n  Scanning for vtable patterns...")
rtti_pattern = b'.?AV'
count = 0
for i in range(len(data) - len(rtti_pattern)):
    if data[i:i+len(rtti_pattern)] == rtti_pattern:
        end = data.index(b'\x00', i)
        rtti_name = data[i:end].decode('ascii', errors='replace')
        print(f"    0x{i:08X}: {rtti_name}")
        count += 1
        if count > 30:
            print(f"  ... ({count} total RTTI names)")
            break

# COM method call analysis: find all indirect calls through registers (call eax, call [ebx+offset], etc.)
print("\n" + "="*60)
print("== COM vtable method calls (call reg/[reg+offset]) ==")
print("="*60)

sec_text = None
for sec_name, v_addr, v_size, r_addr, r_size in sections:
    if sec_name == '.text':
        sec_text = (v_addr, r_addr, r_size)
        break

if sec_text:
    v_addr, r_addr, r_size = sec_text
    code = data[r_addr:r_addr+r_size]
    md2 = Cs(CS_ARCH_X86, CS_MODE_32)
    md2.detail = False

    # Look for call [reg+offset] and call reg patterns (COM vtable dispatch)
    com_calls = []
    for insn in md2.disasm(code, 0x10000000):
        if insn.mnemonic == "call":
            op = insn.op_str
            # call [reg+offset] - COM vtable call
            # call reg - COM function pointer call
            is_com_call = False
            if '[' in op and ('eax' in op.lower() or 'ecx' in op.lower() or 'edx' in op.lower() or
                            'ebx' in op.lower() or 'esi' in op.lower() or 'edi' in op.lower()):
                is_com_call = True
            elif op.lower() in ['eax', 'ecx', 'edx', 'ebx', 'esi', 'edi']:
                is_com_call = True

            if is_com_call:
                # Get the previous few instructions to understand context
                com_calls.append((insn.address, insn.op_str))

    # Find references to known IAT entries near COM calls
    print(f"  Found {len(com_calls)} potential COM vtable calls")

    # Search for the IAT addresses
    # CoCreateInstance IAT
    iat_base = None
    for name, v_addr, v_size, r_addr, r_size in sections:
        if name == '.idata':
            iat_base = r_addr
            break

    if iat_base:
        iat = data[iat_base:iat_base+sections[2][4]]  # .idata SizeOfRawData
        print(f"\n  IAT at FO: 0x{iat_base:08X}")
        # Find all addresses in the text section that reference IAT entries
        for sec_name2, v_addr2, v_size2, r_addr2, r_size2 in sections:
            if sec_name2 == '.text':
                text_code = data[r_addr2:r_addr2+r_size2]
                # Search for 'ff 15' (call dword ptr [...]) patterns
                for i in range(len(text_code) - 5):
                    if text_code[i:i+2] == b'\xff\x15':
                        # This is a call dword ptr [address]
                        target_rva = struct.unpack_from('<I', text_code, i+2)[0]
                        target_va = 0x10000000 + target_rva
                        # Check if target is in IAT
                        for imp_name, imp_va, imp_vs, imp_ro, imp_rs in sections:
                            if imp_name == '.idata':
                                if imp_va <= target_rva < imp_va + imp_vs:
                                    rdata_off = rva_to_offset(target_rva)
                                    if rdata_off:
                                        # Try to identify which API this is
                                        print(f"     0x{r_addr2+i:08X}: call ds:0x{target_rva:08X} [IAT?]")

print("\nAnalysis complete")
print(f"Output dir: {OUTPUT_DIR}")
