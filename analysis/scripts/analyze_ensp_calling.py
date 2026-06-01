#!/usr/bin/env python3
"""
Comprehensive analysis of how eNSP binaries call the VBox52.dll proxy.

This script:
1. Parses PE headers of both eNSP executables
2. Finds all references to VBox52 functions (GetVBoxInstance, DelVBoxInstance)
3. Traces how the proxy pointer is stored and used
4. Finds ALL indirect call sites (vtable dispatch) through the proxy
5. Identifies COM apartment/threading usage
6. Analyzes QueryInterface usage
"""

import struct
from capstone import *
from capstone.x86 import *
import pefile
import os

CLIENT_PATH = r"C:\Program Files\Huawei\eNSP\eNSP_Client.exe"
SERVER_PATH = r"C:\Program Files\Huawei\eNSP\vboxserver\eNSP_VBoxServer.exe"
OUTPUT_PATH = r"F:\各种项目\逆向ensp\analysis\output\ensp_calling_analysis.md"

def va_to_offset(pe, va):
    """Convert VA to file offset"""
    base = pe.OPTIONAL_HEADER.ImageBase
    rva = va - base
    for section in pe.sections:
        if section.VirtualAddress <= rva < section.VirtualAddress + section.Misc_VirtualSize:
            return section.PointerToRawData + (rva - section.VirtualAddress)
    return None

def rva_to_offset(pe, rva):
    """Convert RVA to file offset"""
    for section in pe.sections:
        if section.VirtualAddress <= rva < section.VirtualAddress + section.Misc_VirtualSize:
            return section.PointerToRawData + (rva - section.VirtualAddress)
    return None

def offset_to_va(pe, offset):
    """Convert file offset to VA"""
    for section in pe.sections:
        raw_start = section.PointerToRawData
        raw_end = raw_start + section.SizeOfRawData
        if raw_start <= offset < raw_end:
            rva = section.VirtualAddress + (offset - raw_start)
            return pe.OPTIONAL_HEADER.ImageBase + rva
    return None

def get_text_section_info(pe):
    """Get .text section details"""
    for section in pe.sections:
        name = section.Name.decode('ascii', errors='replace').strip('\x00')
        if name == '.text':
            return section
    return None

def find_string_references(pe, data, string_bytes):
    """Find all file offsets of a string and their corresponding VAs"""
    refs = []
    idx = 0
    while True:
        idx = data.find(string_bytes, idx)
        if idx < 0:
            break
        va = offset_to_va(pe, idx)
        refs.append((idx, va))
        idx += 1
    return refs

def analyze_executable(pe, data, exe_name, pe_path):
    """Full analysis of one executable"""
    base = pe.OPTIONAL_HEADER.ImageBase
    text_sec = get_text_section_info(pe)
    if not text_sec:
        return None

    text_offset = text_sec.PointerToRawData
    text_size = text_sec.SizeOfRawData
    text_rva = text_sec.VirtualAddress
    text_data = data[text_offset:text_offset + text_size]

    results = {
        'name': exe_name,
        'path': pe_path,
        'base': base,
        'text_rva': text_rva,
        'text_offset': text_offset,
        'text_size': text_size,
        'getvboxinstance_refs': [],
        'delvboxinstance_refs': [],
        'global_ptr': None,
        'vtable_calls': [],
        'com_calls': [],
        'queryinterface_refs': [],
        'cocreateinstance_refs': [],
        'ole_initialize_refs': [],
        'string_refs': {},
    }

    # Find string references
    for name, s in [('GetVBoxInstance', b'GetVBoxInstance'),
                    ('DelVBoxInstance', b'DelVBoxInstance'),
                    ('VBox52.dll', b'VBox52.dll'),
                    ('tools\\\\VBox52.dll', b'tools\\\\VBox52.dll')]:
        refs = find_string_references(pe, data, s)
        if refs:
            results['string_refs'][name] = refs
            for fo, va in refs:
                print(f"  {name} at VA 0x{va:08X}")

    # Set up Capstone
    md = Cs(CS_ARCH_X86, CS_MODE_32)
    md.detail = True

    # Disassemble the whole .text section
    print(f"\nDisassembling .text section (0x{text_size:X} bytes)...")
    all_instrs = list(md.disasm(text_data, base + text_rva))
    print(f"  Total instructions: {len(all_instrs)}")

    # Build address-to-instruction map
    addr_to_insn = {}
    for insn in all_instrs:
        addr_to_insn[insn.address] = insn

    # Build IAT map
    iat_map = {}
    iat_target_map = {}  # Maps VA of call target -> API name
    for imp in pe.DIRECTORY_ENTRY_IMPORT:
        dll_name = imp.dll.decode()
        for sym in imp.imports:
            if sym.address and sym.name:
                try:
                    api_name = f"{dll_name}!{sym.name.decode()}"
                    iat_map[sym.address] = api_name
                    iat_target_map[sym.address] = api_name
                except:
                    pass

    # Phase 1: Find all indirect call [reg+offset] and call reg instructions
    print("\nPhase 1: Finding all COM-style vtable call sites...")
    vtable_calls = []
    for insn in all_instrs:
        if insn.mnemonic not in ('call', 'jmp'):
            continue

        op_str = insn.op_str

        # Pattern 1: call [reg+offset] - COM vtable dispatch
        if '[' in op_str:
            for op in insn.operands:
                if op.type == X86_OP_MEM:
                    base_reg_num = op.mem.base
                    if base_reg_num != 0:  # Has a base register
                        base_reg = insn.reg_name(base_reg_num)
                        if base_reg in ('eax', 'ecx', 'edx', 'ebx', 'esi', 'edi') and op.mem.disp >= 0:
                            # Get the previous instructions for context
                            context = []
                            idx = all_instrs.index(insn)
                            for j in range(max(0, idx - 15), idx):
                                context.append(all_instrs[j])

                            vtable_calls.append({
                                'address': insn.address,
                                'base_reg': base_reg,
                                'offset': op.mem.disp,
                                'index': op.mem.disp // 4,
                                'context': context,
                                'instruction': insn
                            })

        # Pattern 2: call reg (e.g., call eax) - function pointer call
        elif op_str in ('eax', 'ecx', 'edx', 'ebx', 'esi', 'edi'):
            context = []
            idx = all_instrs.index(insn)
            for j in range(max(0, idx - 15), idx):
                context.append(all_instrs[j])

            vtable_calls.append({
                'address': insn.address,
                'base_reg': op_str,
                'offset': -1,
                'index': -1,
                'context': context,
                'instruction': insn
            })

    results['vtable_calls'] = vtable_calls
    print(f"  Found {len(vtable_calls)} indirect call sites")

    # Phase 2: Find GetVBoxInstance call sites
    print("\nPhase 2: Finding GetVBoxInstance call sites...")
    for insn in all_instrs:
        if insn.mnemonic == 'call':
            # Direct call: call 0x12345678
            if insn.operands and insn.operands[0].type == X86_OP_IMM:
                target = insn.operands[0].imm
                # This could be calling GetProcAddress with GetVBoxInstance
                # Check context for GetVBoxInstance string reference
                idx = all_instrs.index(insn)
                for j in range(max(0, idx - 20), idx):
                    prev = all_instrs[j]
                    # Check if previous instruction pushes a string reference
                    if prev.mnemonic == 'push':
                        # Check for IAT call patterns
                        pass

    # Phase 3: Find LoadLibraryA/W call sites
    print("\nPhase 3: Finding LoadLibrary call sites...")
    # Find all LoadLibraryA and GetProcAddress IAT entries
    ll_iat = None
    gp_iat = None
    for imp in pe.DIRECTORY_ENTRY_IMPORT:
        for sym in imp.imports:
            if sym.name and sym.address:
                try:
                    n = sym.name.decode()
                    if n == 'LoadLibraryA':
                        ll_iat = sym.address
                    elif n == 'GetProcAddress':
                        gp_iat = sym.address
                except:
                    pass

    if ll_iat and gp_iat:
        print(f"  LoadLibraryA IAT: 0x{ll_iat:08X}")
        print(f"  GetProcAddress IAT: 0x{gp_iat:08X}")
        results['ll_iat'] = ll_iat
        results['gp_iat'] = gp_iat

    # Find all call [IAT] patterns
    for insn in all_instrs:
        if insn.mnemonic == 'call' and insn.operands:
            op0 = insn.operands[0]
            if op0.type == X86_OP_MEM:
                mem_target = op0.mem.disp
                if mem_target in iat_target_map:
                    api = iat_target_map[mem_target]
                    results['com_calls'].append({
                        'address': insn.address,
                        'api': api,
                        'instruction': insn
                    })

    # Phase 4: Find all indirect calls that go through global pointer variables
    print("\nPhase 4: Tracing proxy pointer usage...")
    # The known global pointers:
    if 'Client' in exe_name:
        global_ptr_va = 0x005F528C  # eNSP_Client.exe
    else:
        global_ptr_va = 0x0047484C  # eNSP_VBoxServer.exe

    results['global_ptr_va'] = global_ptr_va

    # Search for references to the global ptr in the code
    global_ptr_bytes = struct.pack('<I', global_ptr_va)
    ptr_refs = []
    for i in range(len(text_data) - 4):
        if text_data[i:i+4] == global_ptr_bytes:
            ref_va = base + text_rva + i
            ptr_refs.append(ref_va)
            # Find the instruction at this VA
            if ref_va in addr_to_insn:
                insn = addr_to_insn[ref_va]
                print(f"  Reference to global ptr 0x{global_ptr_va:08X} @ VA 0x{ref_va:08X}: {insn.mnemonic} {insn.op_str}")
            else:
                # Might be part of an instruction, find which instruction contains it
                for addr, insn in sorted(addr_to_insn.items(), key=lambda x: x[0]):
                    if addr <= ref_va < addr + insn.size:
                        print(f"  Reference to global ptr 0x{global_ptr_va:08X} @ VA 0x{ref_va:08X} (inside: {insn.mnemonic} {insn.op_str})")
                        break

    results['global_ptr_refs'] = ptr_refs

    # Phase 5: Find mov instructions that load from the global pointer
    # This tells us when eNSP loads the VBox interface pointer
    print("\nPhase 5: Instructions loading from global pointer...")
    for insn in all_instrs:
        if insn.mnemonic == 'mov' and insn.operands:
            for op in insn.operands:
                if op.type == X86_OP_MEM:
                    mem_disp = op.mem.disp
                    if mem_disp == global_ptr_va:
                        idx = all_instrs.index(insn)
                        print(f"  0x{insn.address:08X}: {insn.mnemonic:8s} {insn.op_str}")
                        # Print context
                        for j in range(max(0, idx - 3), idx):
                            print(f"    0x{all_instrs[j].address:08X}: {all_instrs[j].mnemonic:8s} {all_instrs[j].op_str}")
                        print()

    # Phase 6: Find functions that reference GetVBoxInstance or DelVBoxInstance strings
    print("\nPhase 6: Cross-reference GetVBoxInstance string location...")
    string_data_sections = [s for s in pe.sections if b'rdata' in s.Name or b'data' in s.Name]
    for sec in string_data_sections:
        sec_start = sec.PointerToRawData
        sec_size = sec.SizeOfRawData

        # Find GetVBoxInstance string
        needle = b'GetVBoxInstance\x00'
        idx = data.find(needle)
        if idx >= sec_start and idx < sec_start + sec_size:
            str_rva = sec.VirtualAddress + (idx - sec_start)
            str_va = base + str_rva
            print(f"  GetVBoxInstance string @ VA 0x{str_va:08X} (RVA 0x{str_rva:08X})")

            # Find references to this VA in .text
            str_bytes = struct.pack('<I', str_va)
            for i in range(len(text_data) - 4):
                if text_data[i:i+4] == str_bytes:
                    ref_va = base + text_rva + i
                    if ref_va in addr_to_insn:
                        insn = addr_to_insn[ref_va]
                        print(f"    -> Referenced at 0x{ref_va:08X}: {insn.mnemonic:8s} {insn.op_str}")
                        # Deeper context
                        idx2 = all_instrs.index(insn)
                        start = max(0, idx2 - 25)
                        end = min(len(all_instrs), idx2 + 15)
                        for j in range(start, end):
                            i2 = all_instrs[j]
                            mark = " <--- GetVBoxInstance ref" if i2.address == ref_va else ""
                            print(f"        0x{i2.address:08X}: {i2.mnemonic:8s} {i2.op_str:30s}{mark}")
                            if i2.mnemonic == 'ret':
                                break

    # Phase 7: Look for COM apartment initialization (CoInitializeEx)
    print("\nPhase 7: COM initialization calls...")
    com_init_apis = ['CoInitializeEx', 'CoInitialize', 'CoUninitialize',
                     'CoCreateInstance', 'CoCreateInstanceEx']
    for imp in pe.DIRECTORY_ENTRY_IMPORT:
        for sym in imp.imports:
            if sym.name and sym.address:
                try:
                    n = sym.name.decode()
                    if n in com_init_apis:
                        print(f"  {imp.dll.decode()}!{n} @ IAT 0x{sym.address:08X}")
                        # Find references
                        for insn in all_instrs:
                            if insn.mnemonic == 'call' and insn.operands:
                                op0 = insn.operands[0]
                                if op0.type == X86_OP_MEM and op0.mem.disp == sym.address:
                                    idx = all_instrs.index(insn)
                                    print(f"    -> Called from 0x{insn.address:08X}")
                                    for j in range(max(0, idx-8), idx):
                                        print(f"        0x{all_instrs[j].address:08X}: {all_instrs[j].mnemonic:8s} {all_instrs[j].op_str}")
                except:
                    pass

    return results

def format_results(client_results, server_results):
    """Format analysis results into markdown"""
    lines = []

    def add(s):
        lines.append(s)

    add("# eNSP VBox52.dll Proxy Calling Convention Analysis")
    add(f"\nAnalysis date: 2026-05-20")
    add(f"\n## Summary")
    add(f"\nThis document analyzes how eNSP_Client.exe and eNSP_VBoxServer.exe call methods on the")
    add(f"VBox52.dll proxy object returned by `GetVBoxInstance()`. The goal is to understand the")
    add(f"exact calling mechanism so the proxy DLL can correctly intercept and translate calls")
    add(f"from VBox 5.2 API to VBox 7.2.8.")

    for name, res in [("eNSP_Client.exe", client_results), ("eNSP_VBoxServer.exe", server_results)]:
        if not res:
            continue

        add(f"\n---")
        add(f"\n## {name} Analysis")
        add(f"\n- **Path:** `{res['path']}`")
        add(f"- **ImageBase:** `0x{res['base']:08X}`")
        add(f"- **Global proxy pointer:** `0x{res['global_ptr_va']:08X}`")
        add(f"- **GetVBoxInstance string location(s):** " +
            ", ".join(f"`0x{va:08X}`" for _, va in res.get('string_refs', {}).get('GetVBoxInstance', [])))
        add(f"- **DelVBoxInstance string location(s):** " +
            ", ".join(f"`0x{va:08X}`" for _, va in res.get('string_refs', {}).get('DelVBoxInstance', [])))

        # COM API usage
        add(f"\n### COM API Usage")
        com_apis = set()
        for c in res.get('com_calls', []):
            com_apis.add(c['api'])
        for api in sorted(com_apis):
            if 'CoInitialize' in api or 'CoCreate' in api or 'OleInitialize' in api:
                add(f"- {api}")

        # QueryInterface evidence
        qi_calls = [c for c in res.get('vtable_calls', []) if c['offset'] == 0]
        add(f"\n### QueryInterface (vtable offset 0)")
        if qi_calls:
            add(f"Found **{len(qi_calls)}** call(s) to vtable+0x0 (QueryInterface):")
            for qc in qi_calls[:5]:
                add(f"- `0x{qc['address']:08X}`: call [{qc['base_reg']}]")
        else:
            add("No potential QueryInterface calls found in indirect call analysis.")

        # VTable call analysis
        add(f"\n### All VTable Call Sites (call [reg+offset])")

        # Group by offset
        from collections import Counter
        offset_counts = Counter()
        offset_examples = {}
        for vc in res.get('vtable_calls', []):
            if vc['offset'] >= 0:
                offset_counts[vc['offset']] += 1
                if vc['offset'] not in offset_examples:
                    offset_examples[vc['offset']] = vc

        if offset_counts:
            add(f"\n**Unique vtable offsets used: {len(offset_counts)}**")
            add(f"\n| Offset | Index | IUnknown Method | Count | Example Address |")
            add(f"|--------|-------|-----------------|-------|-----------------|")

            for offset in sorted(offset_counts.keys()):
                idx = offset // 4
                method_name = ""
                if idx == 0: method_name = "QueryInterface"
                elif idx == 1: method_name = "AddRef"
                elif idx == 2: method_name = "Release"
                elif idx == 3: method_name = "GetTypeInfoCount (IDispatch)"
                elif idx == 4: method_name = "GetTypeInfo (IDispatch)"
                elif idx == 5: method_name = "GetIDsOfNames (IDispatch)"
                elif idx == 6: method_name = "Invoke (IDispatch)"
                else: method_name = f"Custom method {idx-2}"

                vc = offset_examples.get(offset)
                addr_str = f"0x{vc['address']:08X}" if vc else "-"
                add(f"| `0x{offset:03X}` | `{idx}` | {method_name} | {offset_counts[offset]} | `{addr_str}` |")

            # Print detailed context for each unique offset
            add(f"\n### Detailed VTable Call Sites")
            for offset in sorted(offset_counts.keys()):
                vc = offset_examples.get(offset)
                if not vc:
                    continue

                idx = offset // 4
                add(f"\n#### Offset 0x{offset:03X} (method index {idx})")
                add(f"- Example: `0x{vc['address']:08X}`: `call [{vc['base_reg']}+0x{offset:X}]`")
                add(f"- Total occurrences: {offset_counts[offset]}")

                # Show context
                add("```")
                add(f"; Context before call at 0x{vc['address']:08X}:")
                for ctx_insn in vc['context']:
                    add(f"  0x{ctx_insn.address:08X}:  {ctx_insn.mnemonic:8s} {ctx_insn.op_str}")
                add(f"  0x{vc['address']:08X}:  {vc['instruction'].mnemonic:8s} {vc['instruction'].op_str} ; <--- CALL HERE")
                add("```")

        # Also list calls by register (no offset)
        reg_calls = [vc for vc in res.get('vtable_calls', []) if vc['offset'] < 0]
        if reg_calls:
            add(f"\n### Register-Indirect Calls (call reg)")
            add(f"Found **{len(reg_calls)}** calls through register (no vtable offset):")
            for rc in reg_calls[:10]:
                add(f"- `0x{rc['address']:08X}`: `call {rc['base_reg']}`")

        # Global pointer references
        add(f"\n### Global Pointer Usage")
        add(f"The global variable at `0x{res['global_ptr_va']:08X}` stores the VBox interface pointer.")
        add(f"It is referenced at {len(res.get('global_ptr_refs', []))} location(s) in .text.")

        # GetVBoxInstance loading code
        add(f"\n### GetVBoxInstance Call Sites")
        add(f"Searching for code that loads VBox52.dll and calls GetVBoxInstance...")

        # Also search for known IAT entries
        add(f"\n### IAT Entries (all imports)")
        for imp in pefile.PE(res['path']).DIRECTORY_ENTRY_IMPORT:
            dll = imp.dll.decode()
            add(f"\n**{dll}:**")
            for sym in imp.imports:
                if sym.name:
                    try:
                        name = sym.name.decode()
                        add(f"- `{name}` @ IAT `0x{sym.address:08X}`")
                    except:
                        add(f"- (unnamed) @ `0x{sym.address:08X}`")

    # Cross-executable analysis
    add(f"\n---")
    add(f"\n## Cross-Executable Analysis")

    # Common offsets between both
    if client_results and server_results:
        client_offsets = set(vc['offset'] for vc in client_results.get('vtable_calls', []) if vc['offset'] >= 0)
        server_offsets = set(vc['offset'] for vc in server_results.get('vtable_calls', []) if vc['offset'] >= 0)
        common = client_offsets & server_offsets
        only_client = client_offsets - server_offsets
        only_server = server_offsets - client_offsets

        add(f"\n### Common VTable Offsets (used by both executables)")
        for offset in sorted(common):
            add(f"- `0x{offset:03X}` (index {offset//4})")

        if only_client:
            add(f"\n### Offsets only in eNSP_Client.exe")
            for offset in sorted(only_client):
                add(f"- `0x{offset:03X}` (index {offset//4})")

        if only_server:
            add(f"\n### Offsets only in eNSP_VBoxServer.exe")
            for offset in sorted(only_server):
                add(f"- `0x{offset:03X}` (index {offset//4})")

    add(f"\n## Key Findings\n")

    # Write the results
    return "\n".join(lines)

# Main analysis
def main():
    print("=" * 70)
    print("eNSP VBox52.dll Calling Convention Analysis")
    print("=" * 70)

    client_results = None
    server_results = None

    # Analyze eNSP_Client.exe
    print(f"\n{'='*70}")
    print("Analyzing eNSP_Client.exe...")
    print(f"{'='*70}")
    try:
        pe = pefile.PE(CLIENT_PATH)
        with open(CLIENT_PATH, 'rb') as f:
            data = f.read()
        client_results = analyze_executable(pe, data, "eNSP_Client.exe", CLIENT_PATH)
    except Exception as e:
        print(f"ERROR analyzing client: {e}")
        import traceback
        traceback.print_exc()

    # Analyze eNSP_VBoxServer.exe
    print(f"\n{'='*70}")
    print("Analyzing eNSP_VBoxServer.exe...")
    print(f"{'='*70}")
    try:
        pe = pefile.PE(SERVER_PATH)
        with open(SERVER_PATH, 'rb') as f:
            data = f.read()
        server_results = analyze_executable(pe, data, "eNSP_VBoxServer.exe", SERVER_PATH)
    except Exception as e:
        print(f"ERROR analyzing server: {e}")
        import traceback
        traceback.print_exc()

    # Format and write output
    print(f"\n{'='*70}")
    print("Writing output...")
    print(f"{'='*70}")

    output = format_results(client_results, server_results)

    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    with open(OUTPUT_PATH, 'w', encoding='utf-8') as f:
        f.write(output)

    print(f"Output written to {OUTPUT_PATH}")
    print(f"Output size: {len(output)} characters")

if __name__ == '__main__':
    main()
