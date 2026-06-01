#!/usr/bin/env python3
"""
Final comprehensive analysis: finds ALL vtable method calls through the VBox proxy
in both executables, with correct global pointer addresses.
"""
from capstone import *
from capstone.x86 import *
import pefile
from collections import Counter

def analyze(path, label, global_ptr_va):
    print(f'\n{"="*70}')
    print(f'{label}')
    print(f'Global ptr: 0x{global_ptr_va:08X}')
    print(f'{"="*70}')

    pe = pefile.PE(path)
    base = pe.OPTIONAL_HEADER.ImageBase
    with open(path, 'rb') as f:
        data = f.read()

    text_sec = None
    for s in pe.sections:
        name = s.Name.decode('ascii', errors='replace').strip('\x00')
        if name == '.text':
            text_sec = s
            break

    text_data = data[text_sec.PointerToRawData:text_sec.PointerToRawData + text_sec.SizeOfRawData]
    text_va = base + text_sec.VirtualAddress

    md = Cs(CS_ARCH_X86, CS_MODE_32)
    md.detail = True
    all_instrs = list(md.disasm(text_data, text_va))
    addr_to_idx = {}
    for idx, insn in enumerate(all_instrs):
        addr_to_idx[insn.address] = idx

    # Build IAT map
    iat_map = {}
    for imp in pe.DIRECTORY_ENTRY_IMPORT:
        dll = imp.dll.decode()
        for sym in imp.imports:
            if sym.name and sym.address:
                try:
                    iat_map[sym.address] = f'{dll}!{sym.name.decode()}'
                except:
                    pass

    # Find ALL instructions that load from global pointer
    gp_loads = []
    for insn in all_instrs:
        if insn.mnemonic == 'mov' and insn.operands and len(insn.operands) >= 2:
            op1 = insn.operands[1]
            if op1.type == X86_OP_MEM and op1.mem.base == 0 and op1.mem.disp == global_ptr_va:
                idx = addr_to_idx[insn.address]
                reg = insn.reg_name(insn.operands[0].reg)
                gp_loads.append((insn, idx, reg))

    print(f'Found {len(gp_loads)} loads from global ptr')

    # For each load, trace forward to find: mov X,[reg]; mov Y,[X+offset]; call Y
    # Also handle the "add reg, N; mov Y, [reg]" variant (VBoxServer)
    all_method_calls = []  # (call_addr, load_addr, method_offset, method_idx, full_chain)
    seen_offsets = set()

    for load_insn, load_idx, load_reg in gp_loads:
        for j in range(load_idx + 1, min(load_idx + 30, len(all_instrs))):
            i2 = all_instrs[j]
            if i2.mnemonic in ('ret', 'retf'):
                break

            # Pattern A: mov X, [load_reg] (deref to vtable)
            # Pattern B: add X, N; mov Y, [X] (alternative deref)
            if i2.mnemonic == 'mov' and len(i2.operands) >= 2:
                src = i2.operands[1]
                if src.type == X86_OP_MEM and src.mem.base != 0:
                    base_reg = insn.reg_name(src.mem.base)
                    if base_reg == load_reg and src.mem.index == 0 and src.mem.disp == 0:
                        vtable_reg = insn.reg_name(i2.operands[0].reg)

                        # Now find: mov Y, [vtable_reg + offset] or add vtable_reg, N; mov Y, [vtable_reg]
                        for k in range(j + 1, min(j + 20, len(all_instrs))):
                            i3 = all_instrs[k]
                            if i3.mnemonic in ('ret', 'retf'):
                                break

                            method_offset = None
                            method_reg = None

                            # Direct: mov Y, [vtable_reg + offset]
                            if i3.mnemonic == 'mov' and len(i3.operands) >= 2:
                                src3 = i3.operands[1]
                                if src3.type == X86_OP_MEM:
                                    base3 = insn.reg_name(src3.mem.base) if src3.mem.base != 0 else None
                                    if base3 == vtable_reg and src3.mem.index == 0:
                                        method_offset = src3.mem.disp
                                        method_reg = insn.reg_name(i3.operands[0].reg)

                            # Alternative: add vtable_reg, N; mov Y, [vtable_reg]
                            if i3.mnemonic == 'add' and len(i3.operands) >= 2:
                                op0 = i3.operands[0]
                                if op0.type == X86_OP_REG:
                                    add_reg = insn.reg_name(op0.reg)
                                    if add_reg == vtable_reg:
                                        # Check what value was added
                                        if i3.operands[1].type == X86_OP_IMM:
                                            add_val = i3.operands[1].imm
                                            # Next instruction might be mov Y, [vtable_reg]
                                            for k2 in range(k + 1, min(k + 5, len(all_instrs))):
                                                i3b = all_instrs[k2]
                                                if i3b.mnemonic == 'mov' and len(i3b.operands) >= 2:
                                                    src3b = i3b.operands[1]
                                                    if src3b.type == X86_OP_MEM:
                                                        base3b = insn.reg_name(src3b.mem.base) if src3b.mem.base != 0 else None
                                                        if base3b == vtable_reg and src3b.mem.index == 0:
                                                            method_offset = add_val
                                                            method_reg = insn.reg_name(i3b.operands[0].reg)
                                                            j = k2  # Adjust for call finding
                                                            break
                                                elif i3b.mnemonic in ('ret', 'retf'):
                                                    break

                            if method_offset is not None and method_reg is not None:
                                # Find the call instruction
                                start_search = k  # Start from the mov/add of method ptr
                                if i3.mnemonic == 'add':
                                    start_search = k  # This is the "add vtable_reg, N" case

                                for k3 in range(start_search + 1, min(start_search + 10, len(all_instrs))):
                                    i4 = all_instrs[k3]
                                    if i4.mnemonic in ('ret', 'retf'):
                                        break
                                    if i4.mnemonic == 'call' and i4.operands:
                                        cop = i4.operands[0]
                                        if cop.type == X86_OP_REG:
                                            call_reg = insn.reg_name(cop.reg)
                                            if call_reg == method_reg:
                                                if method_offset not in seen_offsets:
                                                    seen_offsets.add(method_offset)

                                                # Print the chain
                                                print(f'\n>>> vtable+0x{method_offset:X} (method[{method_offset//4}])')
                                                print(f'    Load from global: 0x{load_insn.address:08X}')
                                                print(f'    Method call: 0x{i4.address:08X}')
                                                print(f'    Chain:')

                                                # Collect the full chain
                                                chain = []
                                                for m in range(load_idx, k3 + 1):
                                                    chain.append(all_instrs[m])

                                                for ci in chain:
                                                    extra = ''
                                                    if ci.mnemonic == 'call' and ci.operands:
                                                        cop = ci.operands[0]
                                                        if cop.type == X86_OP_MEM and cop.mem.disp in iat_map:
                                                            extra = f'  ; {iat_map[cop.mem.disp]}'
                                                    marker = '  *** CALL' if ci.address == i4.address else ''
                                                    marker2 = '  <<< LOAD' if ci.address == load_insn.address else ''
                                                    print(f'    0x{ci.address:08X}: {ci.mnemonic:8s} {ci.op_str:30s}{extra}{marker}{marker2}')

                                                # Check for between-chain pushes (parameters)
                                                pushes_between = []
                                                for m in range(load_idx, k3):
                                                    ci = all_instrs[m]
                                                    if ci.mnemonic == 'push':
                                                        pushes_between.append(ci)
                                                    elif ci.mnemonic == 'call':
                                                        pushes_between = []  # Reset - was a separate call

                                                if pushes_between:
                                                    print(f'    Pre-call parameters:')
                                                    for pi in pushes_between:
                                                        print(f'      0x{pi.address:08X}: {pi.mnemonic:8s} {pi.op_str}')

                                                break
                            if method_offset is not None:
                                break

    # Also collect ALL vtable->method->call patterns across the entire binary
    print(f'\n\nAll proxy method calls (summary):')
    print(f'{"Offset":>8} {"Idx":>4} {"Count":>6} {"First Call Addr":>16}')
    print(f'{"-"*40}')

    for offset in sorted(seen_offsets):
        calls_at_offset = [c for c in all_method_calls if c[2] == offset]
        print(f'  0x{offset:03X}    {offset//4:>4}    {len(calls_at_offset):>6}')

    return seen_offsets

# Also check string references near push instructions to understand method types
def check_string_refs():
    print(f'\n\n{"="*70}')
    print(f'String reference analysis')
    print(f'{"="*70}')

    for path, label in [
        (r'C:\Program Files\Huawei\eNSP\eNSP_Client.exe', 'Client'),
        (r'C:\Program Files\Huawei\eNSP\vboxserver\eNSP_VBoxServer.exe', 'Server')
    ]:
        pe = pefile.PE(path)
        base = pe.OPTIONAL_HEADER.ImageBase
        with open(path, 'rb') as f:
            data = f.read()

        # Find all strings in .rdata near known addresses
        for s in pe.sections:
            sname = s.Name.decode('ascii', errors='replace').strip('\x00')
            if 'rdata' not in sname:
                continue

            sec_data = data[s.PointerToRawData:s.PointerToRawData + s.SizeOfRawData]

            # Find the push addresses used in the proxy call functions
            # Looking for GUID-like strings
            if 'Client' in label:
                addresses = [0x5ac190, 0x5ac1f8, 0x5ac214, 0x5ac238, 0x5ac2a0, 0x5ac2bc,
                            0x5ac2e0, 0x5ac348, 0x5ac364, 0x5ac388, 0x5ac3f4, 0x5ac410,
                            0x5ac438, 0x5ac48c, 0x5ac49c, 0x5ac660, 0x5ac6b8, 0x5ac710,
                            0x5ac768, 0x5ac7c8, 0x5ac810, 0x5ac878, 0x5ac8e0, 0x5ac948,
                            0x5ac9b0]
            else:
                addresses = []

            for addr in addresses:
                rva = addr - base
                offset = s.PointerToRawData + (rva - s.VirtualAddress)
                if offset < s.PointerToRawData or offset >= s.PointerToRawData + s.SizeOfRawData:
                    continue
                # Read up to 100 chars or until null
                end = sec_data.find(b'\x00', rva - s.VirtualAddress)
                if end < 0:
                    end = min(rva - s.VirtualAddress + 100, len(sec_data))
                string_val = sec_data[rva - s.VirtualAddress:end]
                # Try to decode as ASCII
                try:
                    text = string_val.decode('ascii', errors='replace')
                    if any(c.isprintable() for c in text):
                        # Only show if it looks meaningful
                        clean_text = ''.join(c if 32 <= ord(c) < 127 else '.' for c in text)
                        if len(clean_text.strip('.')) > 2:
                            print(f'  {label}: 0x{addr:08X}: "{clean_text}"')
                except:
                    # Show as hex
                    print(f'  {label}: 0x{addr:08X}: hex={string_val[:20].hex()}')

print('COMPREHENSIVE ANALYSIS')
r1 = analyze(r'C:\Program Files\Huawei\eNSP\eNSP_Client.exe', 'eNSP_Client.exe', 0x005F528C)
r2 = analyze(r'C:\Program Files\Huawei\eNSP\vboxserver\eNSP_VBoxServer.exe', 'eNSP_VBoxServer.exe', 0x0047448C)
check_string_refs()
