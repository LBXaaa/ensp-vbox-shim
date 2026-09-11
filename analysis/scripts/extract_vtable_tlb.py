#!/usr/bin/env python3
"""
extract_vtable_tlb.py — dump COM interface vtable layout from VBoxProxyStub.dll

Parses the type library embedded in VBoxProxyStub[_x86].dll with comtypes and
prints the vtable slot layout (sorted by FUNCDESC.oVft) for the interfaces
named on the command line (default: IVirtualBox, IMachine).

This is the same method used to derive the 7.2.8 layout in
analysis/output/vbox728_vtable.md — run it on any new VBox build's proxy stub
to detect vtable drift before touching the shim.

Usage:
    python extract_vtable_tlb.py <path-to-VBoxProxyStub.dll> [IfaceName ...]

Example:
    python extract_vtable_tlb.py "C:\\Program Files\\Oracle\\VirtualBox\\VBoxProxyStub.dll" IVirtualBox IMachine
"""
import sys

from comtypes.typeinfo import LoadTypeLibEx, ITypeInfo

# invkind constants from COM (INVOKEKIND)
INVKIND = {1: "func", 2: "propget", 4: "propput", 8: "propputref"}


def dump_interface(tlib, want_name):
    count = tlib.GetTypeInfoCount()
    for i in range(count):
        ti = tlib.GetTypeInfo(i)
        ti = ti.QueryInterface(ITypeInfo)
        doc = ti.GetDocumentation(-1)
        if not doc or doc[0] != want_name:
            continue
        ta = ti.GetTypeAttr()
        print(f"=== {want_name} (typekind={ta.typekind}, cFuncs={ta.cFuncs}, cbSizeVft={ta.cbSizeVft}) ===")
        rows = []
        for j in range(ta.cFuncs):
            fd = ti.GetFuncDesc(j)
            d = ti.GetDocumentation(fd.memid)
            name = d[0] if d else "?"
            rows.append((fd.oVft, fd.memid, name, INVKIND.get(fd.invkind, fd.invkind)))
            # NOTE: comtypes GetFuncDesc() returns an auto-releasing wrapper
            # (_deref_with_release); calling ReleaseFuncDesc again double-frees.
        rows.sort(key=lambda r: (r[0], r[1]))
        prev = None
        for oVft, memid, name, kind in rows:
            gap = ""
            if prev is not None and oVft > prev + 4:
                gap = f"   <-- gap {oVft - prev - 4} bytes"
            print(f"  vft+0x{oVft:03x} idx[{oVft // 4:3d}] memid={memid:#010x} {kind:8s} {name}{gap}")
            prev = oVft
        return True
    print(f"!!! interface {want_name} not found in typelib")
    return False


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    path = sys.argv[1]
    names = sys.argv[2:] or ["IVirtualBox", "IMachine"]
    tlib = LoadTypeLibEx(path)
    for n in names:
        dump_interface(tlib, n)
        print()


if __name__ == "__main__":
    main()
