// spoof_thunks.cpp - IVirtualBox vtable[3..6] spoof thunks.
//
// CRITICAL (2026-07-13): NGFW_Plugin.dll calls vtable[3]/[4]/[5] as bare
// __thiscall with ZERO stack args (ecx=this, no params on stack). Using
// ret 4 causes stack imbalance -> cascade crash -> NGFW_Plugin.dll unloaded
// -> error 45 "initialization failed".
//
// Fix: return S_OK (0) with ret (zero args). NGFW checks HRESULT
// (test eax,eax; jge/jl). S_OK(0) passes the check (0 >= 0 -> jge taken),
// enabling the registration path to proceed to clonevm.
//
// Previous E_FAIL (0x80004005) caused error 45 because NGFW treats negative
// HRESULT as init failure and aborts. Previous ret 4 caused stack corruption
// because NGFW doesn't push a stack arg.
//
// Call convention: bare __thiscall, ecx=this (proxy), zero stack args, ret 0.
//
// Actual call sites (from NGFW_Plugin_dll.c):
//   vtable[3] @ FUN_1000df70:12288  bare thiscall (get_version probe)
//   vtable[4] @ FUN_1000dbe0:12134  bare thiscall (get_versionNormalized probe)
//   vtable[5] @ FUN_1000dbe0:12186  bare thiscall (get_revision probe)
//   vtable[6] not called by NGFW
#include <windows.h>
#include <objbase.h>

// vtable[3] get_version probe — return S_OK
extern "C" __declspec(naked) void spoof_get_version() {
    __asm {
        xor  eax, eax       ; S_OK (0) — passes NGFW HRESULT check (jge)
        ret                 ; zero args (bare thiscall)
    }
}

// vtable[4] get_versionNormalized probe — return S_OK
extern "C" __declspec(naked) void spoof_get_versionNormalized() {
    __asm {
        xor  eax, eax       ; S_OK
        ret
    }
}

// vtable[5] get_revision probe — return S_OK
extern "C" __declspec(naked) void spoof_get_revision() {
    __asm {
        xor  eax, eax       ; S_OK
        ret
    }
}

// vtable[6] get_packageType — not called by NGFW, return S_OK for safety
extern "C" __declspec(naked) void spoof_get_packageType() {
    __asm {
        xor  eax, eax       ; S_OK
        ret
    }
}
