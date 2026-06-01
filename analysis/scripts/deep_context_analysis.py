#!/usr/bin/env python3
"""
Deep context analysis: For each function that uses the proxy global pointer,
print the FULL function body to see parameter setup.
"""
from capstone import *
from capstone.x86 import *
import pefile

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

    # IAT
    iat_map = {}
    for imp in pe.DIRECTORY_ENTRY_IMPORT:
        dll = imp.dll.decode()
        for sym in imp.imports:
            if sym.name and sym.address:
                try:
                    iat_map[sym.address] = f'{dll}!{sym.name.decode()}'
                except:
                    pass

    # Find each global ptr load and show FULL function context
    gp_loads = []
    for insn in all_instrs:
        if insn.mnemonic == 'mov' and insn.operands and len(insn.operands) >= 2:
            op1 = insn.operands[1]
            if op1.type == X86_OP_MEM and op1.mem.base == 0 and op1.mem.disp == global_ptr_va:
                idx = addr_to_idx[insn.address]
                gp_loads.append((insn, idx))

    print(f'\nFound {len(gp_loads)} loads from global pointer [0x{global_ptr_va:08X}]')

    for load_insn, load_idx in gp_loads:
        # Find function start by going backward
        func_start = None
        for j in range(load_idx, max(0, load_idx - 500), -1):
            if all_instrs[j].mnemonic == 'ret':
                if j + 1 < len(all_instrs):
                    func_start = all_instrs[j + 1].address
                    break
            if all_instrs[j].mnemonic == 'push' and all_instrs[j].operands:
                op = all_instrs[j].operands[0]
                if op.type == X86_OP_REG and op.reg == 13:  # push ebp
                    func_start = all_instrs[j].address
                    break

        if func_start is None:
            func_start = all_instrs[max(0, load_idx - 50)].address

        # Find function end (next ret or end of function)
        func_start_idx = addr_to_idx.get(func_start, 0)
        func_end_idx = min(func_start_idx + 200, len(all_instrs))

        # Find the vtable method call after this load
        method_info = None
        for j in range(load_idx + 1, min(load_idx + 30, len(all_instrs))):
            i2 = all_instrs[j]
            if i2.mnemonic in ('ret', 'retf'):
                break
            # Look for the 3-instruction pattern: mov X,[proxy_reg]; mov Y,[X+off]; call Y
            if i2.mnemonic == 'mov':
                src = i2.operands[1] if len(i2.operands) >= 2 else None
                if src and src.type == X86_OP_MEM:
                    base_reg_name = insn.reg_name(src.mem.base) if src.mem.base != 0 else ''
                    if base_reg_name == 'ecx' and src.mem.index == 0 and src.mem.disp == 0:
                        vtable_reg = insn.reg_name(i2.operands[0].reg)
                        for k in range(j + 1, min(j + 15, len(all_instrs))):
                            i3 = all_instrs[k]
                            if i3.mnemonic in ('ret', 'retf'):
                                break
                            if i3.mnemonic == 'mov' and len(i3.operands) >= 2:
                                src3 = i3.operands[1]
                                if src3.type == X86_OP_MEM and insn.reg_name(src3.mem.base) == vtable_reg and src3.mem.index == 0:
                                    method_offset = src3.mem.disp
                                    method_reg = insn.reg_name(i3.operands[0].reg)
                                    for k2 in range(k + 1, min(k + 10, len(all_instrs))):
                                        i4 = all_instrs[k2]
                                        if i4.mnemonic in ('ret', 'retf'):
                                            break
                                        if i4.mnemonic == 'call' and i4.operands:
                                            cop = i4.operands[0]
                                            if cop.type == X86_OP_REG and insn.reg_name(cop.reg) == method_reg:
                                                method_info = (load_insn, method_offset, method_offset//4, i4.address)
                                                break
                                if method_info:
                                    break
                    if method_info:
                        break
            if method_info:
                break

        if method_info:
            _, method_offset, method_idx, call_addr = method_info
            print(f'\n{"-"*60}')
            print(f'Function at 0x{func_start:08X}')
            print(f'Proxy load at 0x{load_insn.address:08X}, vtable+0x{method_offset:X} (method[{method_idx}])')
            print(f'Call at 0x{call_addr:08X}')
            print(f'{"-"*60}')
        else:
            print(f'\n{"-"*60}')
            print(f'Function at 0x{func_start:08X}')
            print(f'Proxy load at 0x{load_insn.address:08X}')
            print(f'(no matching vtable call pattern found)')
            print(f'{"-"*60}')

        # Print full function context - 50 before load, up to call or 80 after
        start_print = max(0, func_start_idx)
        end_print = min(func_end_idx, load_idx + 80)

        for j in range(start_print, end_print):
            i2 = all_instrs[j]
            extra = ''
            if i2.mnemonic in ('call',) and i2.operands:
                op = i2.operands[0]
                if op.type == X86_OP_MEM and op.mem.disp in iat_map:
                    extra = f'  ; IAT: {iat_map[op.mem.disp]}'
            marker = ''
            if i2.address == load_insn.address:
                marker = '  <<< LOAD PROXY PTR'
            elif method_info and i2.address == method_info[3]:
                marker = f'  <<< CALL vtable+0x{method_offset:X}'

            # Highlight push instructions that might be parameters
            is_param = ''
            if i2.mnemonic == 'push' and j > load_idx - 20 and j < (method_info[3] if method_info else load_idx + 30):
                is_param = ' [PARAM]' if method_info and j < addr_to_idx.get(method_info[3], j) else ''

            print(f'  0x{i2.address:08X}: {i2.mnemonic:8s} {i2.op_str:30s}{extra}{is_param}{marker}')
            if i2.mnemonic == 'ret' and j > load_idx:
                break

    # Also find VBoxServer global pointer usage
    if 'Server' in label:
        print(f'\n\n=== VBoxServer: Searching for global pointer usage via different patterns ===')
        # Maybe they stored a copy or used a different variable
        # Search for [0x47448c] as literal bytes
        gp_bytes = global_ptr_va.to_bytes(4, 'little')
        count = 0
        for i in range(len(text_data) - 4):
            if text_data[i:i+4] == gp_bytes:
                ref_va = text_va + i
                if ref_va in addr_to_idx:
                    ref_idx = addr_to_idx[ref_va]
                    insn = all_instrs[ref_idx]
                    print(f'  Reference at 0x{ref_va:08X}: {insn.mnemonic:8s} {insn.op_str}')
                    count += 1
                    if count >= 20:
                        break

analyze(r'C:\Program Files\Huawei\eNSP\eNSP_Client.exe', 'eNSP_Client.exe', 0x005F528C)
analyze(r'C:\Program Files\Huawei\eNSP\vboxserver\eNSP_VBoxServer.exe', 'eNSP_VBoxServer.exe', 0x0047484C)
