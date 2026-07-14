#!/usr/bin/env python3
"""Compare NGFW_Plugin.dll vs VAR_Plugin.dll (pristine) to see whether the AR
vtable-remap patch table transfers to the firewall plugin."""
import hashlib

HERE = __file__.rsplit("\\", 1)[0]
ngfw = bytearray(open(HERE + r"\NGFW_Plugin.dll", "rb").read())
var  = bytearray(open(HERE + r"\VAR_Plugin.orig.dll", "rb").read())

print(f"ngfw size={len(ngfw)} sha={hashlib.sha256(ngfw).hexdigest()[:16]}")
print(f"var  size={len(var)}  sha={hashlib.sha256(var).hexdigest()[:16]}")

# byte-diff summary
diffs = [i for i in range(min(len(ngfw), len(var))) if ngfw[i] != var[i]]
print(f"total differing bytes: {len(diffs)} / {len(var)} ({100*len(diffs)/len(var):.1f}%)")
if diffs:
    print(f"first diff @0x{diffs[0]:06X}  last diff @0x{diffs[-1]:06X}")

# The VAR patch table (pristine col). Check what NGFW holds at those offsets.
PATCH_TABLE = [
    (0x0168C8, 0x9C, 0xD8, "getExtraData"),
    (0x0168DD, 0x9C, 0xD8, "getExtraData"),
    (0x0172BA, 0xB4, 0xBC, "openMedium"),
    (0x01754C, 0x88, 0xCC, "createSharedFolder"),
    (0x0177DC, 0xB0, 0x9C, "openMachine"),
    (0x017F03, 0x88, 0xCC, "createSharedFolder"),
    (0x01BF35, 0x9C, 0xD8, "getExtraData"),
    (0x01ED4B, 0x8C, 0xB4, "createUnattendedInstaller"),
    (0x01ED99, 0x90, 0xE8, "findDHCPServerByNetworkName"),
    (0x01EDF3, 0x94, 0xA4, "findMachine"),
    (0x01EE4D, 0x98, 0xF4, "findNATNetworkByName"),
    (0x01EEA7, 0x9C, 0xD8, "getExtraData"),
    (0x01EF01, 0xA0, 0xD4, "getExtraDataKeys"),
    (0x01EF5B, 0xA4, 0xC0, "getGuestOSType"),
    (0x01EFB5, 0xA8, 0xAC, "getMachineStates"),
    (0x01F00F, 0xAC, 0xA8, "getMachinesByGroups"),
    (0x01F06C, 0xB0, 0x9C, "openMachine"),
    (0x01F0C6, 0xB4, 0xBC, "openMedium"),
    (0x01F114, 0xB8, 0xA0, "registerMachine"),
    (0x01F162, 0xBC, 0xEC, "removeDHCPServer"),
    (0x01F1BC, 0xC0, 0xF8, "removeNATNetwork"),
    (0x01F216, 0xC4, 0xD0, "removeSharedFolder"),
    (0x01F279, 0xC8, 0xDC, "setExtraData"),
    (0x01F2D6, 0xCC, 0xE0, "setSettingsSecret"),
    (0x01F32A, 0xD0, 0x18, "checkFirmwarePresent"),
    (0x01F32B, 0x00, 0x01, "checkFirmwarePresent"),
    (0x01FE99, 0x90, 0xE8, "findDHCPServerByNetworkName"),
    (0x0216F8, 0x94, 0xA4, "findMachine"),
    (0x021FFA, 0x88, 0xCC, "createSharedFolder"),
]
print("\n-- VAR patch offsets, byte in NGFW --")
match = 0
for off, pris, patched, name in PATCH_TABLE:
    nb = ngfw[off]
    tag = "==pristine" if nb == pris else ("==patched" if nb == patched else "DIFF")
    if nb == pris:
        match += 1
    print(f"0x{off:06X} var_pris={pris:02X} ngfw={nb:02X} {tag}  {name}")
print(f"\n{match}/{len(PATCH_TABLE)} NGFW bytes equal VAR pristine at same offsets")
