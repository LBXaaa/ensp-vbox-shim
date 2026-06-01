#!/usr/bin/env python3
"""
Extract detailed calling convention for each vtable method used through proxy.
eNSP uses 'call reg' pattern (not 'call [reg+offset]'):
  mov ecx, [global_ptr]     ; load proxy interface ptr
  mov reg, [ecx]            ; deref to vtable
  mov reg2, [reg + offset]  ; load function ptr from vtable
  call reg2                 ; call it

We need to find what parameters are passed before each call.
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

    # Find all proxy pointer dereference chains
    print(f'\nAll dereference chains from global ptr [0x{global_ptr_va:08X}]:\n')

    chains = []
    for insn in all_instrs:
        if insn.mnemonic == 'mov' and insn.operands:
            if len(insn.operands) >= 2:
                op1 = insn.operands[1]
                if op1.type == X86_OP_MEM and op1.mem.base == 0 and op1.mem.disp == global_ptr_va:
                    idx = addr_to_idx[insn.address]
                    reg = insn.reg_name(insn.operands[0].reg)

                    # Now trace the chain to find the actual method call
                    found_method = False
                    for j in range(idx + 1, min(idx + 30, len(all_instrs))):
                        i2 = all_instrs[j]

                        # Stop at ret
                        if i2.mnemonic in ('ret', 'retf'):
                            break

                        # Pattern: mov X, [reg]  (dereference: get vtable ptr)
                        if i2.mnemonic == 'mov' and i2.operands:
                            if len(i2.operands) >= 2:
                                src = i2.operands[1]
                                if src.type == X86_OP_MEM and insn.reg_name(src.mem.base) == reg and src.mem.index == 0 and src.mem.disp == 0:
                                    vtable_reg = insn.reg_name(i2.operands[0].reg)
                                    # Now look for: mov X, [vtable_reg + offset] (load method ptr)
                                    for k in range(j + 1, min(j + 15, len(all_instrs))):
                                        i3 = all_instrs[k]
                                        if i3.mnemonic in ('ret', 'retf'):
                                            break
                                        if i3.mnemonic == 'mov' and i3.operands:
                                            if len(i3.operands) >= 2:
                                                src3 = i3.operands[1]
                                                if src3.type == X86_OP_MEM and insn.reg_name(src3.mem.base) == vtable_reg:
                                                    if src3.mem.index == 0:
                                                        method_offset = src3.mem.disp
                                                        method_reg = insn.reg_name(i3.operands[0].reg)
                                                        method_name = {0:'QueryInterface', 4:'AddRef', 8:'Release'}.get(method_offset, f'Method[{method_offset//4}]')

                                                        # Now look for the actual call instruction
                                                        for k2 in range(k + 1, min(k + 10, len(all_instrs))):
                                                            i4 = all_instrs[k2]
                                                            if i4.mnemonic in ('ret', 'retf'):
                                                                break
                                                            if i4.mnemonic == 'call':
                                                                # Check if calling through the loaded method reg or through another
                                                                call_target = None
                                                                if i4.operands and i4.operands[0].type == X86_OP_REG:
                                                                    call_target = insn.reg_name(i4.operands[0].reg)
                                                                if call_target == method_reg or call_target == 'eax' or True:
                                                                    # FOUND THE METHOD CALL!
                                                                    found_method = True

                                                                    # Now collect push instructions before the call
                                                                    # Look back from the call instruction for push operations
                                                                    pushes = []
                                                                    for p in range(k2 - 1, idx - 1, -1):
                                                                        if p < 0:
                                                                            break
                                                                        pi = all_instrs[p]
                                                                        if pi.mnemonic == 'push':
                                                                            if pi.operands and pi.operands[0].type == X86_OP_IMM:
                                                                                pushes.append(('IMM', pi.operands[0].imm, pi.address))
                                                                            elif pi.operands and pi.operands[0].type == X86_OP_REG:
                                                                                pushes.append(('REG', insn.reg_name(pi.operands[0].reg), pi.address))
                                                                            elif pi.operands and pi.operands[0].type == X86_OP_MEM:
                                                                                pushes.append(('MEM', f'[{insn.reg_name(pi.operands[0].mem.base)}+0x{pi.operands[0].mem.disp:X}]' if pi.operands[0].mem.base != 0 else f'[0x{pi.operands[0].mem.disp:08X}]', pi.address))
                                                                            else:
                                                                                pushes.append(('OTHER', pi.op_str, pi.address))
                                                                        elif pi.mnemonic == 'call':
                                                                            break  # Stop at another call
                                                                        elif pi.mnemonic == 'mov' and pi.operands:
                                                                            # Check for ecx setup (thiscall)
                                                                            if len(pi.operands) >= 2:
                                                                                if pi.operands[0].type == X86_OP_REG and insn.reg_name(pi.operands[0].reg) == 'ecx':
                                                                                    src_op = pi.operands[1]
                                                                                    if src_op.type == X86_OP_IMM:
                                                                                        pushes.append(('ECX', f'0x{src_op.imm:X}', pi.address))
                                                                                    elif src_op.type == X86_OP_REG:
                                                                                        pushes.append(('ECX', insn.reg_name(src_op.reg), pi.address))
                                                                                    elif src_op.type == X86_OP_MEM:
                                                                                        pushes.append(('ECX', f'[{insn.reg_name(src_op.mem.base)}+0x{src_op.mem.disp:X}]' if src_op.mem.base != 0 else f'[0x{src_op.mem.disp:08X}]', pi.address))

                                                                    # Print the entire chain
                                                                    print(f'Chain from 0x{insn.address:08X}:')
                                                                    print(f'  {insn.address:08X}: {insn.mnemonic:8s} {insn.op_str}')
                                                                    for m in range(idx + 1, k2 + 1):
                                                                        mi = all_instrs[m]
                                                                        extra = ''
                                                                        if mi.mnemonic == 'call' and mi.operands:
                                                                            op = mi.operands[0]
                                                                            if op.type == X86_OP_MEM and op.mem.disp in iat_map:
                                                                                extra = f'  ; {iat_map[op.mem.disp]}'
                                                                            elif op.type == X86_OP_REG and op.reg != 0:
                                                                                rname = insn.reg_name(op.reg)
                                                                                if rname == method_reg:
                                                                                    extra = f'  ; <<< vtable+0x{method_offset:X} (method {method_offset//4})'
                                                                        marker = ' <--' if mi.address == i4.address else ''
                                                                        print(f'  {mi.address:08X}: {mi.mnemonic:8s} {mi.op_str:30s}{extra}{marker}')

                                                                    # Print parameters
                                                                    if pushes:
                                                                        print(f'  Parameters (reversed - first push = last param):')
                                                                        for ptype, pval, paddr in reversed(pushes):
                                                                            print(f'    0x{paddr:08X}: push {ptype}:{pval}')
                                                                    else:
                                                                        print(f'  Parameters: none (stdcall with no args, or thiscall with ecx only)')
                                                                    print()
                                                                    break
                                                            if found_method:
                                                                break
                                                        if found_method:
                                                            break
                                if found_method:
                                    break
                        if found_method:
                            break

    # Now also do a more comprehensive search across ALL instructions for the pattern:
    # mov ecx, [0x5f528c]; mov eax, [ecx]; mov XXX, [eax+OFFSET]; call XXX
    print(f'\nAll proxy method calls (comprehensive search):')
    print(f'Format: Address: mov ecx,[global] -> mov X,[ecx] -> mov Y,[X+off] -> call Y')
    print(f'(and parameter context)\n')

    # Track which offsets we've reported
    reported_offsets = set()

    # Scan for patterns: load from global ptr
    for insn in all_instrs:
        if insn.mnemonic == 'mov' and insn.operands and len(insn.operands) >= 2:
            op1 = insn.operands[1]
            if op1.type == X86_OP_MEM and op1.mem.base == 0 and op1.mem.disp == global_ptr_va:
                idx = addr_to_idx[insn.address]
                proxy_reg = insn.reg_name(insn.operands[0].reg)

                # Scan forward for dereference and method call
                # We allow up to ~20 instructions for the full pattern
                for j in range(idx + 1, min(idx + 30, len(all_instrs))):
                    i2 = all_instrs[j]
                    if i2.mnemonic in ('ret', 'retf'):
                        break

                    # mov [some_reg], [proxy_reg] - deref to get vtable
                    if i2.mnemonic == 'mov' and len(i2.operands) >= 2:
                        src = i2.operands[1]
                        if src.type == X86_OP_MEM and insn.reg_name(src.mem.base) == proxy_reg and src.mem.index == 0 and src.mem.disp == 0:
                            vtable_reg = insn.reg_name(i2.operands[0].reg)

                            for k in range(j + 1, min(j + 20, len(all_instrs))):
                                i3 = all_instrs[k]
                                if i3.mnemonic in ('ret', 'retf'):
                                    break

                                if i3.mnemonic == 'mov' and len(i3.operands) >= 2:
                                    src3 = i3.operands[1]
                                    if src3.type == X86_OP_MEM and insn.reg_name(src3.mem.base) == vtable_reg and src3.mem.index == 0:
                                        method_offset = src3.mem.disp
                                        method_reg = insn.reg_name(i3.operands[0].reg)
                                        method_idx = method_offset // 4

                                        for k2 in range(k + 1, min(k + 15, len(all_instrs))):
                                            i4 = all_instrs[k2]
                                            if i4.mnemonic in ('ret', 'retf'):
                                                break
                                            if i4.mnemonic == 'call' and i4.operands:
                                                cop = i4.operands[0]
                                                if cop.type == X86_OP_REG:
                                                    call_reg = insn.reg_name(cop.reg)
                                                    if call_reg == method_reg or call_reg == 'eax':
                                                        # Found! Print context if we haven't reported this offset yet
                                                        if method_offset not in reported_offsets:
                                                            reported_offsets.add(method_offset)
                                                            print(f'--- vtable+0x{method_offset:X} (method[{method_idx}]) ---')
                                                            print(f'  Function entry: TODO')

                                                        # Print the chain
                                                        is_new = '(NEW)' if method_offset in reported_offsets else ''
                                                        print(f'  Call at 0x{i4.address:08X}{is_new}:')
                                                        for m in range(idx, k2 + 1):
                                                            mi = all_instrs[m]
                                                            extra = ''
                                                            if mi.mnemonic == 'call' and mi.operands:
                                                                op = mi.operands[0]
                                                                if op.type == X86_OP_MEM and op.mem.disp in iat_map:
                                                                    extra = f'  ; {iat_map[op.mem.disp]}'
                                                            marker = ' ***' if mi.address == i4.address else ''
                                                            print(f'    0x{mi.address:08X}: {mi.mnemonic:8s} {mi.op_str:30s}{extra}{marker}')

                                                        # Collect parameters
                                                        pushes = []
                                                        for p in range(k2 - 1, idx - 1, -1):
                                                            pi = all_instrs[p]
                                                            if pi.mnemonic == 'call':
                                                                break
                                                            if pi.mnemonic == 'push':
                                                                op = pi.operands[0]
                                                                if op.type == X86_OP_IMM:
                                                                    pushes.append(f'push 0x{op.imm:08X}')
                                                                elif op.type == X86_OP_REG:
                                                                    pushes.append(f'push {insn.reg_name(op.reg)}')
                                                                elif op.type == X86_OP_MEM:
                                                                    if op.mem.base != 0:
                                                                        pushes.append(f'push [{insn.reg_name(op.mem.base)}+0x{op.mem.disp:X}]')
                                                                    else:
                                                                        pushes.append(f'push [0x{op.mem.disp:08X}]')
                                                                else:
                                                                    pushes.append(f'push {pi.op_str}')
                                                        if pushes:
                                                            print(f'  Params (in order right before call):')
                                                            for p in reversed(pushes):
                                                                print(f'    {p}')
                                                        else:
                                                            print(f'  Params: none visible (could be thiscall)')
                                                        print()
                                                        break  # Only show first occurrence per chain
                                            if method_offset in reported_offsets:
                                                break

    return reported_offsets

analyze(r'C:\Program Files\Huawei\eNSP\eNSP_Client.exe', 'eNSP_Client.exe', 0x005F528C)
analyze(r'C:\Program Files\Huawei\eNSP\vboxserver\eNSP_VBoxServer.exe', 'eNSP_VBoxServer.exe', 0x0047484C)
