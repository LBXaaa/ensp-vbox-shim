#!/usr/bin/env python3
"""
Deep analysis: trace the GetVBoxInstance/DelVBoxInstance loading code and
find exact vtable calls made through the proxy.
"""
import struct
from capstone import *
from capstone.x86 import *
import pefile

CLIENT = r"C:\Program Files\Huawei\eNSP\eNSP_Client.exe"
SERVER = r"C:\Program Files\Huawei\eNSP\vboxserver\eNSP_VBoxServer.exe"

def va_to_offset(pe, va):
    base = pe.OPTIONAL_HEADER.ImageBase
    rva = va - base
    for s in pe.sections:
        if s.VirtualAddress <= rva < s.VirtualAddress + s.Misc_VirtualSize:
            return s.PointerToRawData + (rva - s.VirtualAddress)
    return None

def offset_to_va(pe, offset):
    for s in pe.sections:
        if s.PointerToRawData <= offset < s.PointerToRawData + s.SizeOfRawData:
            rva = s.VirtualAddress + (offset - s.PointerToRawData)
            return pe.OPTIONAL_HEADER.ImageBase + rva
    return None

def get_text_data(pe, data):
    for s in pe.sections:
        name = s.Name.decode('ascii', errors='replace').strip('\x00')
        if name == '.text':
            return s, data[s.PointerToRawData:s.PointerToRawData + s.SizeOfRawData]
    return None, None

def analyze(pe_path, label, global_ptr_va):
    print(f"\n{'='*70}")
    print(f"=== {label} ===")
    print(f"{'='*70}")

    pe = pefile.PE(pe_path)
    base = pe.OPTIONAL_HEADER.ImageBase
    with open(pe_path, 'rb') as f:
        data = f.read()

    text_sec, text_data = get_text_data(pe, data)
    if not text_sec:
        print("No .text section!")
        return

    # Build IAT map
    iat_map = {}
    for imp in pe.DIRECTORY_ENTRY_IMPORT:
        dll = imp.dll.decode()
        for sym in imp.imports:
            if sym.address and sym.name:
                try:
                    iat_map[sym.address] = f"{dll}!{sym.name.decode()}"
                except:
                    pass

    md = Cs(CS_ARCH_X86, CS_MODE_32)
    md.detail = True

    print(f"\n1. Searching for GetVBoxInstance string references in code...")
    # Find GetVBoxInstance string
    needle = b'GetVBoxInstance\x00'
    str_idx = data.find(needle)
    str_va = offset_to_va(pe, str_idx) if str_idx >= 0 else None
    print(f"   String at VA 0x{str_va:08X}")

    # Find all PUSH instructions that reference this string VA
    str_va_bytes = struct.pack('<I', str_va)
    all_instrs = list(md.disasm(text_data, base + text_sec.VirtualAddress))
    addr_map = {}
    for insn in all_instrs:
        addr_map[insn.address] = insn

    # Find push of GetVBoxInstance string
    for insn in all_instrs:
        if insn.mnemonic == 'push' and insn.operands:
            op0 = insn.operands[0]
            if op0.type == X86_OP_IMM and op0.imm == str_va:
                # Found a push of GetVBoxInstance address
                idx = all_instrs.index(insn)
                print(f"\n   Found push of GetVBoxInstance @ 0x{insn.address:08X}")
                print(f"   Context (function containing this):")
                # Print 40 instructions before and 30 after
                start = max(0, idx - 40)
                end = min(len(all_instrs), idx + 30)
                for j in range(start, end):
                    i = all_instrs[j]
                    # Resolve IAT calls
                    extra = ""
                    if i.mnemonic == 'call' and i.operands:
                        op = i.operands[0]
                        if op.type == X86_OP_MEM and op.mem.disp in iat_map:
                            extra = f"  ; {iat_map[op.mem.disp]}"
                    marker = " <---" if i.address == insn.address else ""
                    print(f"    0x{i.address:08X}: {i.mnemonic:8s} {i.op_str:35s}{extra}{marker}")
                    if i.mnemonic == 'ret' and j > idx + 5:
                        break

    # Also find GetVBoxInstance string in .rdata and trace its references
    print(f"\n2. Searching for cross-references to GetVBoxInstance string...")
    # Search for the string VA in the full text section data
    for i in range(len(text_data) - 4):
        chunk = text_data[i:i+4]
        if chunk == str_va_bytes:
            insn_va = base + text_sec.VirtualAddress + i
            if insn_va in addr_map:
                insn = addr_map[insn_va]
                print(f"   Reference @ 0x{insn_va:08X}: {insn.mnemonic:8s} {insn.op_str}")

    print(f"\n3. Searching for global pointer usage...")
    # The global pointer variable
    gp_bytes = struct.pack('<I', global_ptr_va)
    for i in range(len(text_data) - 4):
        chunk = text_data[i:i+4]
        if chunk == gp_bytes:
            insn_va = base + text_sec.VirtualAddress + i
            if insn_va in addr_map:
                insn = addr_map[insn_va]
                print(f"   Reference @ 0x{insn_va:08X}: {insn.mnemonic:8s} {insn.op_str}")

    # Find all instructions that load from general global vars (for proxy)
    # Look for patterns: mov ecx/eax/edx, dword ptr [0x???????]
    # followed by call [ecx/eax/edx + offset]
    print(f"\n4. Tracing proxy pointer load -> vtable call chains...")

    # Find ALL mov reg, dword ptr [0x???????] instructions then check if followed by vtable call
    gp_loads = []
    for insn in all_instrs:
        if insn.mnemonic == 'mov' and insn.operands:
            # Pattern: mov reg, dword ptr [address]
            if len(insn.operands) >= 2 and insn.operands[1].type == X86_OP_MEM and insn.operands[1].mem.base == 0:
                src_addr = insn.operands[1].mem.disp
                if src_addr == global_ptr_va:
                    dst_reg = insn.reg_name(insn.operands[0].reg)
                    idx = all_instrs.index(insn)
                    # Look for vtable calls that use this register in the next ~20 instructions
                    for j in range(idx + 1, min(idx + 25, len(all_instrs))):
                        next_insn = all_instrs[j]
                        if next_insn.mnemonic in ('call', 'jmp'):
                            op_str = next_insn.op_str
                            # Check if this instruction uses dst_reg
                            found = False
                            if '[' in op_str and f'{dst_reg}' in op_str:
                                found = True
                            elif op_str == dst_reg:
                                found = True
                            if found:
                                print(f"\n   Chain starting @ 0x{insn.address:08X}: {insn.mnemonic:8s} {insn.op_str}")
                                print(f"     -> 0x{next_insn.address:08X}: {next_insn.mnemonic:8s} {next_insn.op_str}")
                                # Print intermediate instructions
                                for k in range(idx + 1, j):
                                    print(f"        0x{all_instrs[k].address:08X}: {all_instrs[k].mnemonic:8s} {all_instrs[k].op_str}")
                                break

    # Also look for: mov reg, [global_ptr] followed by mov reg, [reg] (dereference to get vtable)
    print(f"\n5. Dereference chains from global pointer...")
    for insn in all_instrs:
        if insn.mnemonic == 'mov' and insn.operands:
            if len(insn.operands) >= 2 and insn.operands[1].type == X86_OP_MEM:
                src = insn.operands[1]
                src_disp = src.mem.disp
                if src_disp == global_ptr_va:
                    reg = insn.reg_name(insn.operands[0].reg)
                    idx = all_instrs.index(insn)
                    # Print up to 15 instructions after
                    for j in range(idx, min(idx + 15, len(all_instrs))):
                        i2 = all_instrs[j]
                        extra = ""
                        if i2.mnemonic == 'call' and i2.operands:
                            op = i2.operands[0]
                            if op.type == X86_OP_IMM:
                                extra = f"  ; target: 0x{op.imm:08X}"
                            elif op.type == X86_OP_MEM and op.mem.disp in iat_map:
                                extra = f"  ; {iat_map[op.mem.disp]}"
                    print(f"\n    From 0x{insn.address:08X} ({reg} = global ptr):")
                    for j in range(idx, min(idx + 15, len(all_instrs))):
                        i2 = all_instrs[j]
                        extra = ""
                        if i2.mnemonic == 'call' and i2.operands:
                            op = i2.operands[0]
                            if op.type == X86_OP_MEM and op.mem.disp in iat_map:
                                extra = f"  ; {iat_map[op.mem.disp]}"
                        print(f"      0x{i2.address:08X}: {i2.mnemonic:8s} {i2.op_str:30s}{extra}")
                    print()

    print(f"\n6. All function entries that contain global pointer references...")
    # Find functions containing the global ptr references
    seen_functions = set()
    for insn in all_instrs:
        if insn.mnemonic == 'mov' and insn.operands:
            if len(insn.operands) >= 2 and insn.operands[1].type == X86_OP_MEM:
                if insn.operands[1].mem.disp == global_ptr_va:
                    idx = all_instrs.index(insn)
                    # Go back to find function start (look for function prologue pattern)
                    func_start = None
                    for j in range(idx, max(0, idx - 200), -1):
                        if all_instrs[j].mnemonic == 'push' and all_instrs[j].operands:
                            op = all_instrs[j].operands[0]
                            if op.type == X86_OP_REG and op.reg == 13:  # push ebp
                                func_start = all_instrs[j].address
                                break
                            elif op.type == X86_OP_REG:
                                # Could be any push reg as start
                                pass
                        if j > 0 and all_instrs[j].mnemonic == 'ret':
                            # Hit previous function's return
                            break
                    if func_start and func_start not in seen_functions:
                        seen_functions.add(func_start)
                        # Collect all vtable calls in this function
                        print(f"\n  Function at 0x{func_start:08X}:")
                        for j in range(idx - (idx - all_instrs.index(insn)) - 10, min(len(all_instrs), all_instrs.index(insn) + 40)):
                            if j >= 0 and j < len(all_instrs):
                                i3 = all_instrs[j]
                                if i3.mnemonic in ('call', 'jmp'):
                                    op_str = i3.op_str
                                    if ('[' in op_str and ('eax' in op_str.lower() or 'ecx' in op_str.lower() or
                                        'edx' in op_str.lower() or 'ebx' in op_str.lower() or
                                        'esi' in op_str.lower() or 'edi' in op_str.lower())) or \
                                        op_str in ('eax', 'ecx', 'edx', 'ebx', 'esi', 'edi'):
                                        extra = ""
                                        if i3.operands and i3.operands[0].type == X86_OP_MEM and i3.operands[0].mem.disp in iat_map:
                                            extra = f"  ; {iat_map[i3.operands[0].mem.disp]}"
                                        print(f"    0x{i3.address:08X}: {i3.mnemonic:8s} {i3.op_str:30s}{extra}")

    # Check for the CVBoxWrapper:: string we saw in VBoxServer
    print(f"\n7. Checking for CVBoxWrapper related strings...")
    for s_str in [b'CVBoxWrapper::', b'VBoxServer', b'IVBoxInterface']:
        si = data.find(s_str)
        if si >= 0:
            sva = offset_to_va(pe, si)
            print(f"   '{s_str.decode(errors='replace')}' at VA 0x{sva:08X}")
            # Show context
            ctx = data[si:si+64]
            printable = ''.join(chr(b) if 32 <= b < 127 else '.' for b in ctx)
            print(f"   Context: {printable}")

    # Now let's find the actual function that loads VBox52.dll
    print(f"\n8. Finding the VBox52.dll loading function...")
    # Look for LoadLibraryA call with a string argument
    prev_instrs = []
    for insn in all_instrs:
        if insn.mnemonic == 'call' and insn.operands:
            op0 = insn.operands[0]
            if op0.type == X86_OP_MEM and op0.mem.disp in iat_map:
                api = iat_map[op0.mem.disp]
                if 'LoadLibraryA' in api or 'GetProcAddress' in api:
                    idx = all_instrs.index(insn)
                    # Print context
                    print(f"\n   {api} call @ 0x{insn.address:08X}:")
                    for j in range(max(0, idx - 10), min(len(all_instrs), idx + 5)):
                        i2 = all_instrs[j]
                        extra = ""
                        if i2.mnemonic == 'call' and i2.operands:
                            op = i2.operands[0]
                            if op.type == X86_OP_MEM and op.mem.disp in iat_map:
                                extra = f"  ; {iat_map[op.mem.disp]}"
                        print(f"      0x{i2.address:08X}: {i2.mnemonic:8s} {i2.op_str:30s}{extra}")

    # VBoxServer specific: find the GetVBoxInstance call and trace
    if 'Server' in label:
        print(f"\n9. VBoxServer: Finding GetVBoxInstance call...")
        # Search for the string in .rdata
        for s in pe.sections:
            sname = s.Name.decode('ascii', errors='replace').strip('\x00')
            if 'rdata' in sname:
                sec_data = data[s.PointerToRawData:s.PointerToRawData + s.SizeOfRawData]
                # Find GetVBoxInstance
                idx = sec_data.find(b'GetVBoxInstance')
                if idx >= 0:
                    str_rva = s.VirtualAddress + idx
                    str_va = base + str_rva
                    print(f"   GetVBoxInstance string @ VA 0x{str_va:08X}")
                    str_bytes = struct.pack('<I', str_va)
                    # Find references in .text
                    for i in range(len(text_data) - 4):
                        if text_data[i:i+4] == str_bytes:
                            ref_va = base + text_sec.VirtualAddress + i
                            print(f"   -> Referenced at VA 0x{ref_va:08X}")
                            # Find the function body
                            if ref_va in addr_map:
                                insn = addr_map[ref_va]
                                insn_idx = all_instrs.index(insn)
                                # Go back to find function start
                                for j in range(insn_idx, max(0, insn_idx - 50), -1):
                                    if all_instrs[j].mnemonic == 'push' and all_instrs[j].operands and \
                                       all_instrs[j].operands[0].type == X86_OP_REG and \
                                       all_instrs[j].operands[0].reg == 13:  # push ebp
                                        func_start = all_instrs[j].address
                                        break
                                print(f"   Function entry: 0x{func_start:08X}")
                                # Print whole function
                                for j in range(max(0, insn_idx - 10), min(len(all_instrs), insn_idx + 40)):
                                    i2 = all_instrs[j]
                                    extra = ""
                                    if i2.mnemonic == 'call' and i2.operands:
                                        op = i2.operands[0]
                                        if op.type == X86_OP_MEM and op.mem.disp in iat_map:
                                            extra = f"  ; {iat_map[op.mem.disp]}"
                                    marker = " <---" if i2.address == ref_va else ""
                                    print(f"      0x{i2.address:08X}: {i2.mnemonic:8s} {i2.op_str:30s}{extra}{marker}")
                                    if i2.mnemonic == 'ret' and j > insn_idx + 5:
                                        break

    # Look for variant strings in both
    print(f"\n10. Looking for string patterns in .rdata...")
    for s in pe.sections:
        sname = s.Name.decode('ascii', errors='replace').strip('\x00')
        if 'rdata' in sname:
            sec_data = data[s.PointerToRawData:s.PointerToRawData + s.SizeOfRawData]
            interesting = [b'VBox52', b'VBox52.dll', b'VBox', b'CVBox', b'IVBox']
            for pat in interesting:
                idx = 0
                while True:
                    idx = sec_data.find(pat, idx)
                    if idx < 0:
                        break
                    str_rva = s.VirtualAddress + idx
                    str_va = base + str_rva
                    end = sec_data.find(b'\x00', idx)
                    sval = sec_data[idx:end].decode('ascii', errors='replace')
                    print(f"   '{sval}' @ VA 0x{str_va:08X}")
                    idx += 1

    print(f"\n=== {label} analysis complete ===")

print("DEEP ANALYSIS OF eNSP VBox52 CALLING PATTERN")
analyze(CLIENT, "eNSP_Client.exe", 0x005F528C)
analyze(SERVER, "eNSP_VBoxServer.exe", 0x0047484C)
