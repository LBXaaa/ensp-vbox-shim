// spoof_thunks.cpp - Pure ASM thunks, safe for exception unwinding
#include <windows.h>
#include <objbase.h>

static const wchar_t g_ver[] = L"5.2.22";

// CVBoxWrapper calls vtable[4] and checks if return == proxy->vtable.
// Must return [proxy] (the vtable pointer), NOT S_OK.
static void* g_spoof_proxy;

extern "C" __declspec(naked) void __stdcall spoof_save_proxy() {
    __asm {
        mov  eax, ecx
        mov  g_spoof_proxy, eax
        ret
    }
}

extern "C" __declspec(naked) void __stdcall spoof_get_vtable() {
    __asm {
        mov  eax, g_spoof_proxy   ; return proxy pointer itself
        ret
    }
}

extern "C" __declspec(naked) void spoof_get_version() {
    __asm {
        call spoof_save_proxy
        pop  edx
        pop  ecx
        push ecx
        push offset g_ver
        call SysAllocString
        pop  ecx
        mov  [ecx], eax
        call spoof_get_vtable
        push edx
        ret
    }
}

extern "C" __declspec(naked) void spoof_get_versionNormalized() {
    __asm {
        call spoof_save_proxy
        pop  edx
        pop  ecx
        push ecx
        push offset g_ver
        call SysAllocString
        pop  ecx
        mov  [ecx], eax
        call spoof_get_vtable
        push edx
        ret
    }
}

extern "C" __declspec(naked) void spoof_get_revision() {
    __asm {
        call spoof_save_proxy
        pop  edx
        pop  ecx
        mov  dword ptr [ecx], 22
        call spoof_get_vtable
        push edx
        ret
    }
}

extern "C" __declspec(naked) void spoof_get_packageType() {
    __asm {
        call spoof_save_proxy
        pop  edx
        pop  ecx
        push ecx
        push offset g_ver
        call SysAllocString
        pop  ecx
        mov  [ecx], eax
        call spoof_get_vtable
        push edx
        ret
    }
}
