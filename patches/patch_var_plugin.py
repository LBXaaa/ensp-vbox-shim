#!/usr/bin/env python3
"""
patch_var_plugin.py -- remap VAR_Plugin.dll (ar1000v) IVirtualBox vtable
offsets from VirtualBox 5.2 slots to VirtualBox 7.2 slots.

Huawei eNSP's AR (ar1000v) router plugin holds a *real* 7.2 IVirtualBox
pointer and dispatches through it with vtable offsets hard-coded for the
5.2 ABI -- bypassing the VBox52.dll proxy entirely. On VBox 7.x those
offsets land on the wrong methods (e.g. findMachine's 5.2 slot 37 hits
7.2's getPlatformProperties) and the plugin crashes. This patcher rewrites
28 call sites (29 bytes) so each dispatch targets the correct 7.2 slot.

This edits ONLY displacement bytes inside `call [reg+disp]` instructions;
no code is added or moved. It is fully reversible (--restore).

The pristine input MUST be the 2019 factory build (size 393216,
SHA256 prefix 5AE6817A...). The patcher refuses to touch anything else.

Usage:
    python patch_var_plugin.py "C:\\Program Files\\Huawei\\eNSP\\plugin\\ar1000v\\VAR_Plugin.dll"
    python patch_var_plugin.py --check   <dll>     # report state, change nothing
    python patch_var_plugin.py --restore <dll>     # revert patched -> pristine
    python patch_var_plugin.py --no-backup <dll>   # skip the .bak copy
"""
import argparse
import hashlib
import os
import shutil
import sys

EXPECT_SIZE = 393216
SHA256_PRISTINE = "5ae6817a9f2f05cfbb5f1f89af910007c22988c22bc02fdf2c44a67a9ff26eb5"
SHA256_PATCHED  = "f0107975ba1b04325af2d31189ee92833233c1163f4553600207789977f94451"

# (file_offset, pristine_byte, patched_byte, method_name)
# Each is one displacement byte of a `call [reg+disp]` IVirtualBox virtual
# dispatch. disp / 4 == vtable slot. See var_plugin_ar1000v.md for the full
# 5.2->7.2 slot derivation. checkFirmwarePresent is the only 2-byte run
# (disp crosses 0xFF: 0x00D0 -> 0x0118).
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
    (0x01F32A, 0xD0, 0x18, "checkFirmwarePresent"),  # low byte of disp
    (0x01F32B, 0x00, 0x01, "checkFirmwarePresent"),  # high byte of disp
    (0x01FE99, 0x90, 0xE8, "findDHCPServerByNetworkName"),
    (0x0216F8, 0x94, 0xA4, "findMachine"),
    (0x021FFA, 0x88, 0xCC, "createSharedFolder"),
]


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def classify(data: bytes) -> str:
    """Return 'pristine', 'patched', or 'unknown' for the given bytes."""
    h = sha256(data)
    if h == SHA256_PRISTINE:
        return "pristine"
    if h == SHA256_PATCHED:
        return "patched"
    return "unknown"


def verify_sites(data: bytes, column: int) -> list:
    """Return list of sites where data does NOT match the expected byte.

    column 1 = pristine byte, column 2 = patched byte.
    """
    bad = []
    for off, pris, patched, name in PATCH_TABLE:
        expect = pris if column == 1 else patched
        if data[off] != expect:
            bad.append((off, expect, data[off], name))
    return bad


def do_check(path: str) -> int:
    data = bytearray(open(path, "rb").read())
    print(f"file   : {path}")
    print(f"size   : {len(data)} (expected {EXPECT_SIZE})")
    print(f"sha256 : {sha256(bytes(data))}")
    state = classify(bytes(data))
    print(f"state  : {state}")
    if state == "unknown":
        # Show how close it is to each known state.
        miss_p = verify_sites(data, 1)
        miss_q = verify_sites(data, 2)
        print(f"         {len(PATCH_TABLE) - len(miss_p)}/{len(PATCH_TABLE)} bytes match pristine")
        print(f"         {len(PATCH_TABLE) - len(miss_q)}/{len(PATCH_TABLE)} bytes match patched")
    return 0


def apply_patch(path: str, restore: bool, backup: bool) -> int:
    data = bytearray(open(path, "rb").read())

    if len(data) != EXPECT_SIZE:
        print(f"[!] size {len(data)} != {EXPECT_SIZE}; not the known VAR_Plugin.dll. Aborting.")
        return 2

    state = classify(bytes(data))
    want_from = "patched" if restore else "pristine"
    want_to   = "pristine" if restore else "patched"
    from_col  = 2 if restore else 1
    to_col    = 1 if restore else 2

    if state == want_to:
        print(f"[=] already {want_to}; nothing to do.")
        return 0
    if state != want_from:
        print(f"[!] file is '{state}', expected '{want_from}'.")
        print(f"    Refusing to {'restore' if restore else 'patch'} an unrecognized binary.")
        return 2

    # Defense in depth: every target byte must hold its expected 'from' value
    # before we touch it, even though the whole-file hash already matched.
    bad = verify_sites(data, from_col)
    if bad:
        print(f"[!] {len(bad)} site(s) hold unexpected bytes; aborting without writing:")
        for off, exp, got, name in bad[:8]:
            print(f"    0x{off:06X} expected {exp:02X} got {got:02X} ({name})")
        return 2

    if backup:
        bak = path + ".bak"
        if not os.path.exists(bak):
            shutil.copy2(path, bak)
            print(f"[+] backup -> {bak}")
        else:
            print(f"[=] backup already exists -> {bak} (kept)")

    for off, pris, patched, name in PATCH_TABLE:
        data[off] = pris if to_col == 1 else patched

    out = bytes(data)
    result = classify(out)
    if result != want_to:
        print(f"[!] post-write hash is '{result}', expected '{want_to}'. NOT saving.")
        return 3

    open(path, "wb").write(out)
    verb = "restored" if restore else "patched"
    print(f"[+] {verb}: {len(PATCH_TABLE)} bytes across "
          f"{len({o for o,_,_,_ in PATCH_TABLE})} offsets")
    print(f"[+] sha256 now {sha256(out)}  ({want_to})")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Remap VAR_Plugin.dll IVirtualBox vtable offsets 5.2 -> 7.2")
    ap.add_argument("dll", help="path to VAR_Plugin.dll (plugin\\ar1000v\\)")
    ap.add_argument("--restore", action="store_true", help="revert patched -> pristine")
    ap.add_argument("--check", action="store_true", help="report state only, change nothing")
    ap.add_argument("--no-backup", action="store_true", help="do not write a .bak copy")
    a = ap.parse_args()

    if not os.path.isfile(a.dll):
        print(f"[!] not found: {a.dll}")
        return 2
    if a.check:
        return do_check(a.dll)
    return apply_patch(a.dll, restore=a.restore, backup=not a.no_backup)


if __name__ == "__main__":
    sys.exit(main())
