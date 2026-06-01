#!/usr/bin/env python3
"""
Dump string parameters used in proxy method calls to identify which VBox APIs.
"""
import pefile
import struct

CLIENT = r'C:\Program Files\Huawei\eNSP\eNSP_Client.exe'

pe = pefile.PE(CLIENT)
base = pe.OPTIONAL_HEADER.ImageBase

with open(CLIENT, 'rb') as f:
    data = f.read()

# Known string addresses from the switch tables in the proxy-calling functions
# These are pushed before the proxy method calls
string_addrs = [
    # From function at 0x48015E (vtable+0x10 / method 4)
    0x5AC190, 0x5AC1F8, 0x5AC214, 0x5AC238, 0x5AC2A0, 0x5AC2BC,
    0x5AC2E0, 0x5AC348, 0x5AC364, 0x5AC388, 0x5AC3F4, 0x5AC410,
    0x5AC438, 0x5AC48C, 0x5AC49C,
    # From function at 0x4805AF (vtable+0x0C / method 3)
    0x5AC1F8, 0x5AC2A0, 0x5AC48C, 0x5AC348, 0x5AC3F4,
    # From function at 0x480BC2 (vtable+0x18 / method 6)
    0x5AC660, 0x5AC6B8, 0x5AC710, 0x5AC768, 0x5AC7C8,
    # From function at 0x480CF4 (vtable+0x14 / method 5)
    0x5AC810, 0x5AC878, 0x5AC8E0, 0x5AC948, 0x5AC9B0,
    0x5AC1F8, 0x5AC2A0, 0x5AC2BC, 0x5AC348, 0x5AC364,
    0x5AC3F4, 0x5AC410, 0x5AC48C, 0x5AC49C,
]

# Also check known GUID strings
guid_strings = [0x5AC020, 0x5AC028, 0x5ABF60, 0x5AC098]

all_addrs = sorted(set(string_addrs + guid_strings))

# Find the .rdata section
for s in pe.sections:
    sname = s.Name.decode('ascii', errors='replace').strip('\x00')
    if 'rdata' not in sname:
        continue

    sec_start = s.PointerToRawData
    sec_size = s.SizeOfRawData
    sec_va = s.VirtualAddress
    sec_data = data[sec_start:sec_start + sec_size]

    for addr in all_addrs:
        rva = addr - base
        offset = rva - sec_va
        if 0 <= offset < sec_size:
            # Try to read as null-terminated string
            end = sec_data.find(b'\x00', offset)
            if end < 0:
                end = min(offset + 200, sec_size)
            raw = sec_data[offset:end]

            # Try ASCII
            try:
                text = raw.decode('ascii')
                if all(32 <= ord(c) < 127 for c in text):
                    print(f'0x{addr:08X} (ASCII): "{text}"')
                    continue
            except:
                pass

            # Try UTF-16
            try:
                text = raw.decode('utf-16-le')
                if any(c.isalpha() for c in text):
                    print(f'0x{addr:08X} (UTF-16): "{text[:50]}"')
                    if len(text) > 50:
                        print(f'  ... (total {len(text)} chars)')
                    continue
            except:
                pass

            # Show as hex if short
            if len(raw) <= 16:
                print(f'0x{addr:08X} (hex): {raw.hex()}')
            elif all(b == 0 for b in raw):
                print(f'0x{addr:08X}: (all zeros)')
            else:
                # Try to find GUID pattern
                if len(raw) >= 16:
                    guid_struct = raw[:16]
                    if len(guid_struct) == 16:
                        try:
                            d1, d2, d3 = struct.unpack('<IHH', guid_struct[:8])
                            rest = guid_struct[8:16]
                            guid_str = f'{{{d1:08X}-{d2:04X}-{d3:04X}-{rest[0]:02X}{rest[1]:02X}-{rest[2]:02X}{rest[3]:02X}{rest[4]:02X}{rest[5]:02X}{rest[6]:02X}{rest[7]:02X}}}'
                            print(f'0x{addr:08X} (GUID): {guid_str}')
                            # Show remaining content after GUID
                            remaining = raw[16:].rstrip(b'\x00')
                            if remaining:
                                try:
                                    rem_text = remaining.decode('ascii', errors='replace')
                                    if any(c.isprintable() for c in rem_text):
                                        print(f'  + suffix: "{rem_text}"')
                                except:
                                    pass
                            continue
                        except:
                            pass

                # Show first bytes
                print(f'0x{addr:08X} (data): {raw[:40].hex()}')
        else:
            print(f'0x{addr:08X}: not in .rdata section')

# Also look at the helper function addresses to see what they do
# Check what's at some key VA addresses
print('\n\n=== Cross-reference: strings near GetVBoxInstance ===')
for s in pe.sections:
    sname = s.Name.decode('ascii', errors='replace').strip('\x00')
    if 'rdata' not in sname:
        continue
    sec_data = data[s.PointerToRawData:s.PointerToRawData + s.SizeOfRawData]

    # Look for interesting strings near the areas we found
    for search_term in [b'AR_Base', b'WLAN', b'VirtualBox', b'IVirtual', b'IMachine',
                        b'ISession', b'Create', b'Open', b'Register', b'Find',
                        b'BSTR', b'GUID', b'IID_']:
        idx = 0
        while True:
            idx = sec_data.find(search_term, idx)
            if idx < 0:
                break
            rva = s.VirtualAddress + idx
            va = base + rva
            # Print context
            start = max(0, idx - 8)
            end = min(idx + search_term + 40, len(sec_data))
            ctx = sec_data[start:end]
            null_end = sec_data.find(b'\x00', idx)
            if null_end > idx:
                sval = sec_data[idx:null_end].decode('ascii', errors='replace')
            else:
                sval = search_term.decode()
            print(f'  Found "{sval}" at VA 0x{va:08X}')
            idx += 1
