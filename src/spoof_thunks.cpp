// spoof_thunks.cpp - Pure ASM thunks for IVirtualBox vtable[3..6] version spoofing.
//
// 2026-07-06: NGFW_Plugin.dll calls IVirtualBox vtable[3]/[4]/[5]/[6] as bare
// __thiscall with ZERO stack args (ecx=this, no out param on stack).
// All return values are checked as HRESULT (test eax,eax; jge/jl).
// No caller reads an out param. So spoof just returns E_FAIL (negative
// HRESULT) to make the caller take its failure/cleanup path.
//
// This is the "known-good" version that was active when FW1 successfully
// booted to login prompt (2026-07-06, with manual vfw_usg registration).
// The manual registration made clonecheck succeed, so NGFW never entered
// its FUN_1000eb40 registration flow -> spoof return value was irrelevant
// to that boot. Kept as baseline.
#include <windows.h>
#include <objbase.h>

static const wchar_t g_ver[] = L"5.2.22";

// Diagnostic hook (defined in vbox52_proxy.cpp). __stdcall(1 arg), callee cleans.
extern "C" void __stdcall spoof_diag(int);

// vtable[3] get_version - NGFW FUN_1000df70 bare thiscall
extern "C" __declspec(naked) void spoof_get_version() {
    __asm {
        push ecx
        push 0
        call dword ptr [spoof_diag]
        pop  ecx
        mov  eax, 80004005h
        ret
    }
}

// vtable[4] get_versionNormalized - NGFW FUN_1000dbe0 bare thiscall
extern "C" __declspec(naked) void spoof_get_versionNormalized() {
    __asm {
        push ecx
        push 1
        call dword ptr [spoof_diag]
        pop  ecx
        mov  eax, 80004005h
        ret
    }
}

// vtable[5] get_revision - NGFW FUN_1000dbe0 else branch bare thiscall
extern "C" __declspec(naked) void spoof_get_revision() {
    __asm {
        push ecx
        push 2
        call dword ptr [spoof_diag]
        pop  ecx
        mov  eax, 80004005h
        ret
    }
}

// vtable[6] get_packageType
extern "C" __declspec(naked) void spoof_get_packageType() {
    __asm {
        push ecx
        push 3
        call dword ptr [spoof_diag]
        pop  ecx
        mov  eax, 80004005h
        ret
    }
}
