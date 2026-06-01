#!/usr/bin/env python3
"""
Reverses eNSP_VBoxServer.exe to find VBoxManage path construction logic.
"""
import struct
from capstone import *
from capstone.x86 import *
import pefile

EXE_PATH = r"C:\Program Files\Huawei\eNSP\vboxserver\eNSP_VBoxServer.exe"
OUTPUT = r"F:\各种项目\逆向ensp\analysis\output\vboxserver_path_analysis.txt"

pe = pefile.PE(EXE_PATH)
BASE = pe.OPTIONAL_HEADER.ImageBase  # 0x00400000

with open(EXE_PATH, 'rb') as f:
    data = bytearray(f.read())

def va_to_offset(va):
    for section in pe.sections:
        if section.VirtualAddress <= (va - BASE) < section.VirtualAddress + section.Misc_VirtualSize:
            return section.PointerToRawData + (va - BASE - section.VirtualAddress)
    return None

# Find the SOFTWARE\\Oracle\\VirtualBox string
needle = b'S\x00O\x00F\x00T\x00W\x00A\x00R\x00E\x00\\\x00O\x00r\x00a\x00c\x00l\x00e\x00\\\x00V\x00i\x00r\x00t\x00u\x00a\x00l\x00B\x00o\x00x\x00'
idx = data.find(needle)
if idx < 0:
    # Try case variations
    print("String not found!")
    exit()

print(f"Found 'SOFTWARE\\Oracle\\VirtualBox' at file offset 0x{idx:08X}")

# The string is in UTF-16LE format. Its VA = find which section it's in + offset
for section in pe.sections:
    name = section.Name.decode('ascii', errors='replace').strip('\x00')
    raw_start = section.PointerToRawData
    raw_end = raw_start + section.SizeOfRawData
    if raw_start <= idx < raw_end:
        rva = section.VirtualAddress + (idx - raw_start)
        string_va = BASE + rva
        print(f"  In section '{name}', RVA=0x{rva:08X}, VA=0x{string_va:08X}")

        # Now find cross-references to this VA
        # Search for the VA bytes in the code section
        va_bytes = struct.pack('<I', string_va)
        print(f"  Searching for references to VA 0x{string_va:08X} (bytes: {va_bytes.hex()})")

        text_section = None
        for s in pe.sections:
            if b'.text' in s.Name:
                text_section = s
                break

        if text_section:
            text_data = data[text_section.PointerToRawData:text_section.PointerToRawData + text_section.SizeOfRawData]
            refs = []
            for i in range(len(text_data) - 4):
                if text_data[i:i+4] == va_bytes:
                    ref_va = BASE + text_section.VirtualAddress + i
                    refs.append(ref_va)
                    print(f"  Reference at VA=0x{ref_va:08X} (FO: 0x{text_section.PointerToRawData + i:08X})")

            if refs:
                # Disassemble the code around the first reference
                md = Cs(CS_ARCH_X86, CS_MODE_32)

                for ref_va in refs[:3]:
                    ref_off = ref_va - BASE - text_section.VirtualAddress
                    # Go back 50 bytes to see the function start
                    start_off = max(0, ref_off - 50)
                    disasm_start_va = BASE + text_section.VirtualAddress + start_off
                    disasm_len = 200

                    code_bytes = text_data[start_off:start_off + disasm_len]

                    print(f"\n  {'='*60}")
                    print(f"  Disassembly around VA=0x{ref_va:08X}:")
                    print(f"  {'='*60}")

                    for insn in md.disasm(code_bytes, disasm_start_va):
                        marker = "  <-- REF" if insn.address == ref_va else ""
                        # Check for IAT calls
                        prefix = ""
                        if insn.mnemonic == "call" and insn.operands and insn.operands[0].type == X86_OP_MEM:
                            target = insn.operands[0].mem.disp
                            # Check if this is an IAT call
                            for imp in pe.DIRECTORY_ENTRY_IMPORT:
                                for sym in imp.imports:
                                    if sym.address and sym.address == target:
                                        prefix = f" ; IAT: {imp.dll.decode()}!{sym.name.decode() if sym.name else 'ord'+str(sym.ordinal)}"

                        print(f"  0x{insn.address:08X}: {insn.mnemonic:8s} {insn.op_str:30s} {prefix}{marker}")

                        if insn.address > ref_va + 80 and insn.mnemonic in ('ret', 'retf'):
                            break
        break
