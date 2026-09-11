// VBox52.dll - VirtualBox 7.x COM proxy for eNSP
// Fixed: thiscall->stdcall conversion in ASM thunks
#include <windows.h>
#include <objbase.h>
#include <psapi.h>
#include <cstdio>
#include <cstring>
#include <oleauto.h>
#include <intrin.h>
#pragma intrinsic(_ReturnAddress)

// ===== Log location =====
// All shim logs go to C:\ProgramData\ensp-vbox-shim\ (created on first use).
// Centralized so logs survive across users/sessions and are easy to find/clean
// on uninstall, instead of being scattered under each user's %TEMP%.
// On failure (e.g. ProgramData unwritable) callers fall back gracefully (no log).
static bool GetLogPath(char* out, size_t cap, const char* fname) {
    char dir[MAX_PATH];
    DWORD n = GetEnvironmentVariableA("ProgramData", dir, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) {
        // Fallback to %TEMP% if ProgramData is somehow unavailable.
        n = GetTempPathA(MAX_PATH, dir);
        if (n == 0 || n >= MAX_PATH) return false;
        if (n + strlen(fname) + 1 >= cap) return false;
        sprintf(out, "%s%s", dir, fname);
        return true;
    }
    char sub[MAX_PATH];
    if ((size_t)n + 18 >= MAX_PATH) return false;
    sprintf(sub, "%s\\ensp-vbox-shim", dir);
    CreateDirectoryA(sub, NULL);   // ok if it already exists
    if (strlen(sub) + strlen(fname) + 2 >= cap) return false;
    sprintf(out, "%s\\%s", sub, fname);
    return true;
}


// ===== VEH crash observer (OBSERVE-ONLY) =====
// NOTE: the previous version scanned the stack for any 0x400000-0x600000 value,
// forced Eip to it, set Ecx=0 and CONTINUE_EXECUTION. That HIJACKED eNSP's
// control flow into arbitrary stack data -- it manufactured the "executing stack
// garbage" crashes (PC=040Exxxx) we were chasing. It also only looked at AV, so
// heap-corruption (c0000374) / stack-cookie (c0000409) first-chance faults were
// invisible. This version logs ALL exception codes and NEVER changes control flow.
extern "C" volatile LONG g_last_method_idx;   // updated by diag_method_call
static LONG WINAPI CrashVEH(EXCEPTION_POINTERS* ep) {
    DWORD code = ep->ExceptionRecord->ExceptionCode;
    // Ignore benign/noise: debug prints, C++ EH unwind, breakpoints, guard pages.
    if (code == 0x40010006 || code == 0xE06D7363 || code == 0x80000003 ||
        code == 0x4001000A || code == 0x406D1388) return EXCEPTION_CONTINUE_SEARCH;

    CONTEXT* c = ep->ContextRecord;
    DWORD esp = c->Esp;
    char buf[1600]; int n = 0;
    n += sprintf(buf + n, "%lu [VEH:%lu] code=0x%08lX firstchance EIP=0x%08lX lastMethod=%ld\n",
        GetTickCount(), GetCurrentProcessId(), code, c->Eip, g_last_method_idx);
    n += sprintf(buf + n, "  EAX=%08lX EBX=%08lX ECX=%08lX EDX=%08lX\n",
        c->Eax, c->Ebx, c->Ecx, c->Edx);
    n += sprintf(buf + n, "  ESI=%08lX EDI=%08lX EBP=%08lX ESP=%08lX\n",
        c->Esi, c->Edi, c->Ebp, esp);
    if (ep->ExceptionRecord->NumberParameters >= 2) {
        n += sprintf(buf + n, "  AV: %s addr=%08lX\n",
            ep->ExceptionRecord->ExceptionInformation[0] ? "WRITE" : "READ",
            (DWORD)ep->ExceptionRecord->ExceptionInformation[1]);
    }
    n += sprintf(buf + n, "  bytes@EIP:");
    for (int i = 0; i < 16; i++) {
        BYTE b; if (ReadProcessMemory(GetCurrentProcess(), (void*)(c->Eip + i), &b, 1, NULL))
            n += sprintf(buf + n, " %02X", b); else { n += sprintf(buf + n, " ??"); break; }
    }
    n += sprintf(buf + n, "\n  stack:");
    for (int i = 0; i < 24; i++) {
        DWORD v; if (ReadProcessMemory(GetCurrentProcess(), (void*)(esp + i*4), &v, 4, NULL))
            n += sprintf(buf + n, " %08lX", v); else { n += sprintf(buf + n, " ????????"); break; }
    }
    n += sprintf(buf + n, "\n");
    char lp[MAX_PATH];
    if (GetLogPath(lp, sizeof(lp), "vbox52_crash.log")) {
        HANDLE h = CreateFileA(lp, FILE_APPEND_DATA, FILE_SHARE_READ|FILE_SHARE_WRITE,
            NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (h != INVALID_HANDLE_VALUE) { DWORD w; WriteFile(h, buf, n, &w, NULL); CloseHandle(h); }
    }
    return EXCEPTION_CONTINUE_SEARCH;   // never alter control flow
}

// ===== IIDs =====
static const IID IID_VBox52_IVBoxInterface =
    {0x9570B9D5, 0xF1A1, 0x448A, {0x10, 0xC5, 0xE1, 0x2F, 0x52, 0x85, 0xAD, 0xAD}};
static const IID IID_VBox7_IVirtualBox =
    {0x2CE10519, 0x3C09, 0x45D8, {0xA1, 0x2D, 0xE8, 0x87, 0x78, 0x61, 0x46, 0xB7}};
static const CLSID CLSID_VirtualBox =
    {0xB1A7A4F2, 0x47B9, 0x4A1E, {0x82, 0xB2, 0x07, 0xCC, 0xD5, 0x32, 0x3C, 0x3F}};
static const IID IID_IUnknown_ =
    {0x00000000, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
static const IID IID_IClassFactory =
    {0x00000001, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};

// ===== Debug logging =====
#define DBG(fmt, ...) do { \
    char _dbg_buf[512]; int _n = sprintf(_dbg_buf, "%lu [VBox52:%lu] " fmt "\n", GetTickCount(), GetCurrentProcessId(), ##__VA_ARGS__); \
    OutputDebugStringA(_dbg_buf); \
    char _log_path[MAX_PATH]; \
    if (GetLogPath(_log_path, sizeof(_log_path), "vbox52_proxy.log")) { \
        HANDLE _h = CreateFileA(_log_path, FILE_APPEND_DATA, FILE_SHARE_READ|FILE_SHARE_WRITE, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL); \
        if(_h != INVALID_HANDLE_VALUE) { DWORD _w; WriteFile(_h, _dbg_buf, strlen(_dbg_buf), &_w, NULL); CloseHandle(_h); } \
    } \
} while(0)

// ===== Proxy structures =====
// Layout: [+0]=vtable, [+4]=self, [+8]=self, [+12]=realVBox
struct VBoxProxyView {
    const void** vtable;      // [+0] returned ptr points here
    void*        self1;       // [+4] self-ref for VBoxServer [+4] access
    void*        self2;       // [+8] self-ref for CVBoxWrapper [+8] access
    IUnknown*    realVBox;    // [+12] real VBox7.2 pointer (thunks read from here)
};
struct VBoxProxyRoot {
    LONG          refCount;   // [-4] from returned ptr
    VBoxProxyView view;       // [+0] returned ptr = &view.vtable
};

// ===== NGFW wrapper getters (genuine VBox52.dll semantics) =====
// The genuine GetVBoxInstance object forwards its vtable slots [3]-[6] into specific
// slots of the inner IVirtualBox.  Slot numbers differ between the 5.2 layout the
// caller was built against and the 7.2 object this shim wraps:
//     5.2[7]  get_APIVersion        -> 7.2[11]
//     5.2[8]  get_APIRevision       -> 7.2[12]
//     5.2[9]  get_homeFolder        -> 7.2[13]
//     5.2[10] get_settingsFilePath  -> 7.2[14]
// The genuine also CHAINS: slot[5] tries 9 then 8 then 10, slot[6] tries 10 then 7
// then 9 -- and both return S_OK as long as the inner object exists; they never
// propagate the inner getter's HRESULT.  The NGFW call sites branch on that value
// (`test eax,eax` / `jl` at 0x1000DE3E..0x1000DE45), so propagating a real failure
// sends it down a path that dereferences locals the successful path never sets up.
static const int kApiVersion   = 11;   // 5.2[7]
static const int kApiRevision  = 12;   // 5.2[8]
static const int kHomeFolder   = 13;   // 5.2[9]
static const int kSettingsFile = 14;   // 5.2[10]

static HRESULT ngfw_call_getter(VBoxProxyView* self, void** out, int idx) {
    if (!out) return E_POINTER;
    *out = NULL;
    if (!self || !self->realVBox) return E_POINTER;
    void** vt = *(void***)self->realVBox;
    if (!vt || !vt[idx]) return E_FAIL;
    DBG("[ngfw] getter idx=%d self=%p real=%p vt=%p fn=%p", idx, self, self->realVBox, vt, vt[idx]);
    // 16 zeroed bytes: get_APIRevision returns LONG64 and writes 8 bytes through the
    // out pointer, so a bare `void*` local would be overflowed by 4 and smash the
    // stack.  A BSTR getter only writes 4, so the buffer covers both.
    typedef HRESULT (__stdcall *Fn)(IUnknown*, void*);
    unsigned char buf[16] = { 0 };
    HRESULT hr = ((Fn)vt[idx])(self->realVBox, (void*)buf);
    void* v = *(void**)buf;
    if (SUCCEEDED(hr)) { *out = v; return S_OK; }
    // No SysFreeString here: a failed call may have left a LONG64 in the buffer, and
    // treating that as a BSTR would fault.  The leak is bounded (one call per Init).
    return hr;
}

// BSTR-returning slots only.  The genuine chains also try 5.2[8] get_APIRevision,
// which is a LONG64 getter -- calling it through a small out buffer is a latent
// overflow in the genuine too (FUN_10004010 uses a 4-byte local); it never fires
// there only because 5.2[9] normally succeeds first.  Dropping it removes that
// hazard without changing what the caller can observe (the value is only used as an
// opaque handle, and a LONG64 is not a valid one).
// wrapper[5] -- the "is the link snapshot still there?" probe that FUN_1000dbe0 runs
// after shelling out `snapshot "vfw_usg" delete "vfw_usg_Link"`.
//
// FUN_1000dbe0 branches on this value at 0x1000DE3E (`test eax,eax` / `jl 0x1000DED0`)
// and its else-branch tail ends with `puStack_18 = -1`, i.e. it reports FAILURE to
// RegisterDevice when both slot[4] and slot[5] came back non-negative.  That inversion
// is correct for this call site: the deletion has already been issued, so "the probe
// did not find it" (negative) is the success case.
//
// Verified live: forcing EAX = 0x80004005 at 0x1000DE3E (slot[5]'s return) let
// FUN_1000dbe0 return success and RegisterDevice advance to step 2 (FUN_1000df70),
// which it had never reached before.
//
// The genuine object reaches the same state by forwarding into the inner IVirtualBox
// and returning E_FAIL whenever that getter yields nothing.
extern "C" HRESULT __stdcall ngfw_notfound(VBoxProxyView* self, void** out) {
    (void)self;
    if (out) *out = NULL;
    return 0x80004005;   // E_FAIL -- "not there", which is what FUN_1000dbe0 wants
}

// wrapper[5] is reached from TWO places that want opposite answers:
//   FUN_1000dbe0 (step 1, "delete baselink") -- satisfied by a NEGATIVE result,
//       but it accepts that from slot[4] just as well (its guard is `iVar8 < 0`),
//   FUN_1000e870 (step 4, "add base link")   -- needs a NON-negative result.
// So the negative has to come from slot[4] and slot[5] must stay S_OK; putting the
// E_FAIL on slot[5] makes step 4 abort.
extern "C" HRESULT __stdcall ngfw_ok(VBoxProxyView* self, void** out) {
    (void)self;
    if (out) *out = NULL;
    return S_OK;
}

// wrapper[6] -- called from FUN_1000dfb0 (step 3, "create base") right before it
// issues the registervm.  That caller only inspects the HRESULT:
//
//     iVar10 = vtable[6](...);
//     if (iVar10 < 0) { ...; return 0xffffffff; }
//
// The returned value is never used, so this does not need to reach into the inner
// object at all.
//
// That matters: forwarding to the realVBox getter (idx 14) crashes.  The shim log
// shows the dispatch itself is sound -- self/real/vt all valid, fn resolved to a
// real proxy-stub entry -- but the stub then faults inside with a wild EIP
// (0xAAFA8562 / 0xF21FF6AD, both unmapped), which is the LOCAL_SERVER marshal path
// coming apart, not a bad vtable index on our side.  Since the caller discards the
// value, returning S_OK directly is both sufficient and avoids that path.
extern "C" HRESULT __stdcall ngfw_chain6(VBoxProxyView* self, void** out) {
    (void)self;
    if (out) *out = NULL;
    return S_OK;
}

// ===== Proxy tracking =====
struct ProxyEntry { VBoxProxyView* proxy; ProxyEntry* next; };
static ProxyEntry* g_proxy_list = NULL;
static CRITICAL_SECTION g_proxy_lock;
static VBoxProxyView* g_cached_proxy = NULL;

static void register_proxy(VBoxProxyView* p) {
    if (!p) return;
    EnterCriticalSection(&g_proxy_lock);
    ProxyEntry* e = (ProxyEntry*)HeapAlloc(GetProcessHeap(), 0, sizeof(ProxyEntry));
    if (e) { e->proxy = p; e->next = g_proxy_list; g_proxy_list = e; }
    LeaveCriticalSection(&g_proxy_lock);
    DBG("[track] register proxy=%p realVBox=%p", p, p->realVBox);
}

// ===== Diagnostic =====
static const char* g_method_names[] = {
    "get_version","get_versionNormalized","get_revision","get_packageType",
    "get_APIVersion","get_APIRevision","get_homeFolder","get_settingsFilePath",
    "get_host","get_systemProperties","get_machines","get_machineGroups",
    "get_hardDisks","get_DVDImages","get_floppyImages","get_progressOperations",
    "get_guestOSTypes","get_sharedFolders","get_performanceCollector",
    "get_DHCPServers","get_NATNetworks","get_eventSource","get_extensionPackManager",
    "get_internalNetworks","get_genericNetworkDrivers","composeMachineFilename",
    "createMachine","openMachine","registerMachine","findMachine",
    "getMachinesByGroups","getMachineStates","createAppliance",
    "createUnattendedInstaller","createMedium","openMedium","getGuestOSType",
    "createSharedFolder","removeSharedFolder","getExtraDataKeys","getExtraData",
    "setExtraData","setSettingsSecret","createDHCPServer",
    "findDHCPServerByNetworkName","removeDHCPServer","createNATNetwork",
    "findNATNetworkByName","removeNATNetwork","checkFirmwarePresent"
};

extern "C" volatile LONG g_last_method_idx = -1;
extern "C" void __stdcall diag_method_call(int method_idx, VBoxProxyView* proxy) {
    g_last_method_idx = method_idx;
    const char* name = (method_idx >= 0 && method_idx < 50) ? g_method_names[method_idx] : "???";
    DBG("[DIAG] %s: proxy=%p", name, proxy);
    if (!proxy) { DBG("[DIAG] %s: null proxy", name); return; }
    IUnknown* realVBox = proxy->realVBox;
    if (!realVBox) { DBG("[DIAG] %s: null realVBox", name); return; }
    DBG("[DIAG] %s: proxy=%p realVBox=%p", name, proxy, realVBox);
}

// Lightweight diagnostic for the naked spoof getters (vtable[3]-[6]), which
// otherwise call nothing loggable. __stdcall(1 arg) so the naked thunk can
// `push idx; call spoof_diag` transparently (callee cleans the arg). Records the
// last-dispatched method both to the log and to g_last_method_idx (readable in a
// post-mortem dump even if the log line didn't flush).
extern "C" void __stdcall spoof_diag(int idx) {
    g_last_method_idx = idx;
    const char* name = (idx >= 0 && idx < 50) ? g_method_names[idx] : "???";
    DBG("[SPOOF] %s (idx=%d)", name, idx);
}

// ===== IUnknown helpers =====
extern "C" HRESULT __stdcall helper_QueryInterface(IUnknown* realVBox, const IID* riid, void** ppv) {
    DBG("[QI] realVBox=%p", realVBox);
    if (!ppv) return E_POINTER;
    *ppv = NULL;
    VBoxProxyView* proxy = NULL;
    EnterCriticalSection(&g_proxy_lock);
    for (ProxyEntry* e = g_proxy_list; e; e = e->next) {
        if (e->proxy->realVBox == realVBox) { proxy = e->proxy; break; }
    }
    LeaveCriticalSection(&g_proxy_lock);
    if (proxy && (*riid == IID_VBox52_IVBoxInterface || *riid == IID_IUnknown_)) {
        *ppv = proxy;
        VBoxProxyRoot* root = (VBoxProxyRoot*)((char*)proxy - 4);
        InterlockedIncrement(&root->refCount);
        DBG("[QI] returning self proxy=%p", proxy);
        return S_OK;
    }
    HRESULT hr = realVBox->QueryInterface(*riid, ppv);
    DBG("[QI] delegated hr=0x%08lX", hr);
    return hr;
}
extern "C" ULONG __stdcall helper_AddRef(IUnknown* realVBox) {
    EnterCriticalSection(&g_proxy_lock);
    for (ProxyEntry* e = g_proxy_list; e; e = e->next) {
        if (e->proxy->realVBox == realVBox) {
            VBoxProxyRoot* root = (VBoxProxyRoot*)((char*)e->proxy - 4);
            LeaveCriticalSection(&g_proxy_lock);
            return (ULONG)InterlockedIncrement(&root->refCount);
        }
    }
    LeaveCriticalSection(&g_proxy_lock);
    DBG("[AR] realVBox=%p (not found)", realVBox);
    return 2;
}
extern "C" ULONG __stdcall helper_Release(IUnknown* realVBox) {
    VBoxProxyRoot* root = NULL;
    EnterCriticalSection(&g_proxy_lock);
    for (ProxyEntry* e = g_proxy_list; e; e = e->next) {
        if (e->proxy->realVBox == realVBox) {
            root = (VBoxProxyRoot*)((char*)e->proxy - 4);
            break;
        }
    }
    LeaveCriticalSection(&g_proxy_lock);
    if (!root) { return realVBox->Release(); }
    LONG ref = InterlockedDecrement(&root->refCount);
    DBG("[RL] realVBox=%p ref=%ld", realVBox, ref);
    if (ref == 0) {
        EnterCriticalSection(&g_proxy_lock);
        for (ProxyEntry** pp = &g_proxy_list; *pp; pp = &(*pp)->next) {
            if ((*pp)->proxy == &root->view) {
                ProxyEntry* tmp = *pp;
                *pp = (*pp)->next;
                HeapFree(GetProcessHeap(), 0, tmp);
                break;
            }
        }
        LeaveCriticalSection(&g_proxy_lock);
        if (root->view.realVBox) root->view.realVBox->Release();
        HeapFree(GetProcessHeap(), 0, root);
        return 0;
    }
    return (ULONG)ref;
}

// Late-bound findMachine via IDispatch (7.2 IVirtualBox is a dual interface).
// Binding by NAME avoids hardcoding any 7.2 vtable offset. Returns S_OK(0) iff a
// machine named `base` exists -> eNSP proceeds to clonevm. `snap` is logged only;
// gating on base existence alone is enough to unblock the CLI clone (which itself
// validates the snapshot), and avoids a second late-bind that could fail spuriously.
static HRESULT clone_check_by_name(IUnknown* realVBox, BSTR base, const wchar_t* snap) {
    IDispatch* disp = NULL;
    HRESULT hr = realVBox->QueryInterface(IID_IDispatch, (void**)&disp);
    if (FAILED(hr) || !disp) {
        DBG("[clonecheck] QI(IDispatch) FAILED hr=0x%08lX -> reporting absent", hr);
        return (HRESULT)0x80004002; // E_NOINTERFACE: report "cannot verify" w/o crash
    }
    OLECHAR* mname = (OLECHAR*)L"findMachine";
    DISPID dispid = 0;
    hr = disp->GetIDsOfNames(IID_NULL, &mname, 1, LOCALE_SYSTEM_DEFAULT, &dispid);
    if (FAILED(hr)) {
        DBG("[clonecheck] GetIDsOfNames(findMachine) FAILED hr=0x%08lX", hr);
        disp->Release();
        return hr;
    }
    VARIANTARG arg; VariantInit(&arg);
    arg.vt = VT_BSTR; arg.bstrVal = base;
    DISPPARAMS dp = { &arg, NULL, 1, 0 };
    VARIANT result; VariantInit(&result);
    EXCEPINFO ei; memset(&ei, 0, sizeof(ei));
    UINT argErr = 0;
    hr = disp->Invoke(dispid, IID_NULL, LOCALE_SYSTEM_DEFAULT,
                      DISPATCH_METHOD, &dp, &result, &ei, &argErr);
    DBG("[clonecheck] Invoke(findMachine,'%S') hr=0x%08lX result.vt=%u snap='%S'",
        base ? base : L"(null)", hr, result.vt, snap ? snap : L"(null)");
    bool found = SUCCEEDED(hr) && (result.vt == VT_DISPATCH || result.vt == VT_UNKNOWN)
                 && result.pdispVal != NULL;
    VariantClear(&result);
    disp->Release();
    return found ? S_OK : (HRESULT)0x80004001;
}

// ===== vtable[1]: clone precondition probe (NOT AddRef) =====
// Ground truth (genuine Huawei VBox52.dll method[1] @0x10001100, re-verified
// statically 2026-05-31): GetVBoxInstance returns a custom 7-slot CVBox object;
// eNSP_VBoxServer calls ONLY vtable[1] on it as a 3-arg (__thiscall, ret 0xc)
// clone-precondition probe, never as COM AddRef.
//   HRESULT method1(this, CStringData* base, CStringData* snap, HRESULT* pOut)
// CRITICAL: base/snap are ATL CString DATA pointers (wchar*), NOT BSTRs. The ATL
// header sits below the pointer: [-0x10]=pStringMgr [-0xc]=nDataLength
// [-8]=nAllocLength [-4]=nRefs. Genuine does SysAllocString(wcslen) before
// passing to realVBox, so we must convert too -- handing the raw CString ptr to a
// cross-process marshalling proxy as a BSTR reads a bogus length prefix.
// Genuine then runs realVBox->[0xC0]->child[0x364]->child[0x38] (5.2 hard offsets).
// We CANNOT reuse 5.2 offsets on a 7.2 realVBox (idx48 there = getGuestOSType ->
// E_NOTIMPL, exactly the 0x80004001 we logged). Instead bind by NAME via IDispatch
// (7.2 IVirtualBox is a dual interface) to skip all version-offset guessing.
// eNSP runs `VBoxManage clonevm <base> --snapshot <snap> ...` iff this returns 0.

// Convert an ATL CString data pointer to a freshly-allocated BSTR.
// Returns NULL for a null/empty source. Caller must SysFreeString.
static BSTR cstring_to_bstr(const wchar_t* cdata) {
    if (!cdata) return NULL;
    // nDataLength lives at [cdata - 0xc] (chars, not bytes) in the ATL header.
    LONG nLen = *(const LONG*)((const BYTE*)cdata - 0xC);
    if (nLen < 0 || nLen > 0x10000) nLen = (LONG)wcslen(cdata); // fall back if header looks wrong
    return SysAllocStringLen(cdata, (UINT)nLen);
}

extern "C" HRESULT __stdcall helper_clone_check(IUnknown* realVBox, const wchar_t* base, const wchar_t* snap, HRESULT* pOut) {
    static volatile LONG s_call_no = 0;
    LONG callno = InterlockedIncrement(&s_call_no);
    void* ret_addr = _ReturnAddress();

    // --- heavy diagnostics: settle the empty-string question with evidence ---
    LONG baseLen = -1, snapLen = -1;
    if (base)  baseLen = *(const LONG*)((const BYTE*)base - 0xC);
    if (snap)  snapLen = *(const LONG*)((const BYTE*)snap - 0xC);
    DBG("[clonecheck#%ld] caller=%p realVBox=%p base=%p('%S' hdrLen=%ld) snap=%p('%S' hdrLen=%ld)",
        callno, ret_addr, realVBox,
        base, base ? base : L"(null)", baseLen,
        snap, snap ? snap : L"(null)", snapLen);

    if (!realVBox) { if (pOut) *pOut = (HRESULT)0xFFFFFFFE; return (HRESULT)0xFFFFFFFE; }

    BSTR bBase = cstring_to_bstr(base);
    HRESULT hr = clone_check_by_name(realVBox, bBase, snap);
    if (bBase) SysFreeString(bBase);
    if (pOut) *pOut = hr;
    return hr;   // 0 => eNSP proceeds with clonevm; nonzero => eNSP skips (no crash)
}

// ===== IMachine proxy =====
// Forward declare ASM thunks
extern "C" void im_e_0(), im_e_1(), im_e_2(), im_e_3(), im_e_4(), im_e_5(), im_e_6(), im_e_7(), im_e_8(), im_e_9();
extern "C" void im_e_10(), im_e_11(), im_e_12(), im_e_13(), im_e_14(), im_e_15(), im_e_16(), im_e_17(), im_e_18(), im_e_19();
extern "C" void im_e_20(), im_e_21(), im_e_22(), im_e_23(), im_e_24(), im_e_25(), im_e_26(), im_e_27(), im_e_28(), im_e_29();
extern "C" void im_e_30(), im_e_31(), im_e_32(), im_e_33(), im_e_34(), im_e_35(), im_e_36(), im_e_37(), im_e_38(), im_e_39();
extern "C" void im_e_40(), im_e_41(), im_e_42(), im_e_43(), im_e_44(), im_e_45(), im_e_46(), im_e_47(), im_e_48(), im_e_49();
extern "C" void im_e_50(), im_e_51(), im_e_52(), im_e_53(), im_e_54(), im_e_55(), im_e_56(), im_e_57(), im_e_58(), im_e_59();
extern "C" void im_e_60(), im_e_61(), im_e_62(), im_e_63(), im_e_64(), im_e_65(), im_e_66(), im_e_67(), im_e_68(), im_e_69();
extern "C" void im_e_70(), im_e_71(), im_e_72(), im_e_73(), im_e_74(), im_e_75(), im_e_76(), im_e_77(), im_e_78(), im_e_79();
extern "C" void im_e_80(), im_e_81(), im_e_82(), im_e_83(), im_e_84(), im_e_85(), im_e_86(), im_e_87(), im_e_88(), im_e_89();
extern "C" void im_e_90(), im_e_91(), im_e_92(), im_e_93(), im_e_94(), im_e_95(), im_e_96(), im_e_97(), im_e_98(), im_e_99();
extern "C" void im_e_100(), im_e_101(), im_e_102(), im_e_103(), im_e_104(), im_e_105(), im_e_106(), im_e_107(), im_e_108(), im_e_109();
extern "C" void im_e_110(), im_e_111(), im_e_112(), im_e_113(), im_e_114(), im_e_115(), im_e_116(), im_e_117(), im_e_118(), im_e_119();
extern "C" void im_e_120(), im_e_121(), im_e_122(), im_e_123(), im_e_124(), im_e_125(), im_e_126(), im_e_127(), im_e_128(), im_e_129();
extern "C" void im_e_130(), im_e_131(), im_e_132(), im_e_133(), im_e_134(), im_e_135(), im_e_136(), im_e_137(), im_e_138(), im_e_139();
extern "C" void im_e_140(), im_e_141(), im_e_142(), im_e_143(), im_e_144(), im_e_145(), im_e_146(), im_e_147(), im_e_148(), im_e_149();
extern "C" void im_e_150(), im_e_151(), im_e_152(), im_e_153(), im_e_154(), im_e_155(), im_e_156(), im_e_157(), im_e_158(), im_e_159();
extern "C" void im_e_160(), im_e_161(), im_e_162(), im_e_163(), im_e_164(), im_e_165(), im_e_166(), im_e_167(), im_e_168(), im_e_169();
extern "C" void im_e_170(), im_e_171(), im_e_172(), im_e_173(), im_e_174();
struct MachineProxy {
    void*        vtable;       // [+0]
    LONG         refCount;     // [+4]
    IUnknown*    realMachine;  // [+8]
    int*         map;          // [+12]
};

// IMachine vtable with VBox 5.2 layout (175 entries pointing to ASM thunks)
static void* g_imachine_vtable[175];

// VBox5.2→VBox7.2 vtable index mapping (start with +4 offset)
static int g_imachine_map[175];

// Native IUnknown thunks for the IMachine proxy (defined in imachine_entries.asm /
// below). Declared here so init_imachine_vtable can install them into slots [0]-[2].
extern "C" void machine_QI(void);
extern "C" void machine_AR(void);
extern "C" void machine_RL(void);

// Initialize vtable (called once) — fills entries with ASM thunk addresses
static void init_imachine_vtable() {
    void* entries[175] = {
        (void*)&im_e_0, (void*)&im_e_1, (void*)&im_e_2, (void*)&im_e_3, (void*)&im_e_4,
        (void*)&im_e_5, (void*)&im_e_6, (void*)&im_e_7, (void*)&im_e_8, (void*)&im_e_9,
        (void*)&im_e_10, (void*)&im_e_11, (void*)&im_e_12, (void*)&im_e_13, (void*)&im_e_14,
        (void*)&im_e_15, (void*)&im_e_16, (void*)&im_e_17, (void*)&im_e_18, (void*)&im_e_19,
        (void*)&im_e_20, (void*)&im_e_21, (void*)&im_e_22, (void*)&im_e_23, (void*)&im_e_24,
        (void*)&im_e_25, (void*)&im_e_26, (void*)&im_e_27, (void*)&im_e_28, (void*)&im_e_29,
        (void*)&im_e_30, (void*)&im_e_31, (void*)&im_e_32, (void*)&im_e_33, (void*)&im_e_34,
        (void*)&im_e_35, (void*)&im_e_36, (void*)&im_e_37, (void*)&im_e_38, (void*)&im_e_39,
        (void*)&im_e_40, (void*)&im_e_41, (void*)&im_e_42, (void*)&im_e_43, (void*)&im_e_44,
        (void*)&im_e_45, (void*)&im_e_46, (void*)&im_e_47, (void*)&im_e_48, (void*)&im_e_49,
        (void*)&im_e_50, (void*)&im_e_51, (void*)&im_e_52, (void*)&im_e_53, (void*)&im_e_54,
        (void*)&im_e_55, (void*)&im_e_56, (void*)&im_e_57, (void*)&im_e_58, (void*)&im_e_59,
        (void*)&im_e_60, (void*)&im_e_61, (void*)&im_e_62, (void*)&im_e_63, (void*)&im_e_64,
        (void*)&im_e_65, (void*)&im_e_66, (void*)&im_e_67, (void*)&im_e_68, (void*)&im_e_69,
        (void*)&im_e_70, (void*)&im_e_71, (void*)&im_e_72, (void*)&im_e_73, (void*)&im_e_74,
        (void*)&im_e_75, (void*)&im_e_76, (void*)&im_e_77, (void*)&im_e_78, (void*)&im_e_79,
        (void*)&im_e_80, (void*)&im_e_81, (void*)&im_e_82, (void*)&im_e_83, (void*)&im_e_84,
        (void*)&im_e_85, (void*)&im_e_86, (void*)&im_e_87, (void*)&im_e_88, (void*)&im_e_89,
        (void*)&im_e_90, (void*)&im_e_91, (void*)&im_e_92, (void*)&im_e_93, (void*)&im_e_94,
        (void*)&im_e_95, (void*)&im_e_96, (void*)&im_e_97, (void*)&im_e_98, (void*)&im_e_99,
        (void*)&im_e_100, (void*)&im_e_101, (void*)&im_e_102, (void*)&im_e_103, (void*)&im_e_104,
        (void*)&im_e_105, (void*)&im_e_106, (void*)&im_e_107, (void*)&im_e_108, (void*)&im_e_109,
        (void*)&im_e_110, (void*)&im_e_111, (void*)&im_e_112, (void*)&im_e_113, (void*)&im_e_114,
        (void*)&im_e_115, (void*)&im_e_116, (void*)&im_e_117, (void*)&im_e_118, (void*)&im_e_119,
        (void*)&im_e_120, (void*)&im_e_121, (void*)&im_e_122, (void*)&im_e_123, (void*)&im_e_124,
        (void*)&im_e_125, (void*)&im_e_126, (void*)&im_e_127, (void*)&im_e_128, (void*)&im_e_129,
        (void*)&im_e_130, (void*)&im_e_131, (void*)&im_e_132, (void*)&im_e_133, (void*)&im_e_134,
        (void*)&im_e_135, (void*)&im_e_136, (void*)&im_e_137, (void*)&im_e_138, (void*)&im_e_139,
        (void*)&im_e_140, (void*)&im_e_141, (void*)&im_e_142, (void*)&im_e_143, (void*)&im_e_144,
        (void*)&im_e_145, (void*)&im_e_146, (void*)&im_e_147, (void*)&im_e_148, (void*)&im_e_149,
        (void*)&im_e_150, (void*)&im_e_151, (void*)&im_e_152, (void*)&im_e_153, (void*)&im_e_154,
        (void*)&im_e_155, (void*)&im_e_156, (void*)&im_e_157, (void*)&im_e_158, (void*)&im_e_159,
        (void*)&im_e_160, (void*)&im_e_161, (void*)&im_e_162, (void*)&im_e_163, (void*)&im_e_164,
        (void*)&im_e_165, (void*)&im_e_166, (void*)&im_e_167, (void*)&im_e_168, (void*)&im_e_169,
        (void*)&im_e_170, (void*)&im_e_171, (void*)&im_e_172, (void*)&im_e_173, (void*)&im_e_174,
    };
    for (int i = 0; i < 175; i++) {
        g_imachine_vtable[i] = entries[i];
        g_imachine_map[i] = i + 4;
    }
    // IUnknown slots must NOT forward through the +4 IDispatch map.
    // Override [0]/[1]/[2] with native handlers (QI/AddRef/Release).
    g_imachine_vtable[0] = (void*)&machine_QI;
    g_imachine_vtable[1] = (void*)&machine_AR;
    g_imachine_vtable[2] = (void*)&machine_RL;
}


static MachineProxy* create_machine_proxy(IUnknown* realMachine) {
    static bool inited = false;
    if (!inited) { init_imachine_vtable(); inited = true; }
    MachineProxy* p = (MachineProxy*)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(MachineProxy));
    if (!p) return NULL;
    p->vtable = g_imachine_vtable;
    p->refCount = 1;
    p->realMachine = realMachine;
    p->map = g_imachine_map;
    return p;
}

// ===== MachineProxy IUnknown helpers (called from machine_QI/AR/RL asm thunks) =====
// CRITICAL: these back the IMachine proxy's [0]/[1]/[2] slots. They must NEVER be
// routed through the +4 IDispatch map (that sent QI/AddRef/Release into
// GetTypeInfo/GetIDsOfNames/Invoke, whose ret N popped the wrong byte count and
// drifted eNSP's stack a few bytes per refcount call -> execute-stack-garbage crash).
// Keep them minimal & reentrant-safe: no logging, no big frames, no I/O.
extern "C" ULONG __stdcall machine_helper_AddRef(MachineProxy* p) {
    if (!p) return 1;
    return (ULONG)InterlockedIncrement(&p->refCount);
}
extern "C" ULONG __stdcall machine_helper_Release(MachineProxy* p) {
    if (!p) return 0;
    LONG ref = InterlockedDecrement(&p->refCount);
    if (ref == 0) {
        IUnknown* rm = p->realMachine;
        HeapFree(GetProcessHeap(), 0, p);
        if (rm) rm->Release();
        return 0;
    }
    return (ULONG)ref;
}
extern "C" HRESULT __stdcall machine_helper_QI(MachineProxy* p, const IID* riid, void** ppv) {
    (void)riid;
    if (!ppv) return E_POINTER;
    *ppv = NULL;
    if (!p) return E_POINTER;
    // eNSP expects the 5.2-layout IMachine proxy back; hand it our own vtable.
    *ppv = p;
    InterlockedIncrement(&p->refCount);
    return S_OK;
}

// ===== IMachine wrapper helpers (called from custom ASM thunks) =====
// Wraps IMachine* returned by findMachine in a VBox5.2-compatible proxy
extern "C" HRESULT __stdcall wrap_findMachine_result(VBoxProxyView* proxy, BSTR name, IUnknown** ppMachine) {
    IUnknown* realVBox = proxy->realVBox;
    if (!realVBox || !ppMachine) return E_POINTER;
    *ppMachine = NULL;
    // Call VBox7.2 real findMachine at vtable[41]
    void* vtbl = *(void**)realVBox;
    HRESULT (__stdcall *realFind)(IUnknown*, BSTR, IUnknown**) =
        (HRESULT (__stdcall*)(IUnknown*, BSTR, IUnknown**))((void**)vtbl)[41];
    HRESULT hr = realFind(realVBox, name, ppMachine);
    if (SUCCEEDED(hr) && *ppMachine) {
        MachineProxy* mp = create_machine_proxy(*ppMachine);
        if (mp) *ppMachine = (IUnknown*)mp;
    }
    return hr;
}

extern "C" HRESULT __stdcall wrap_openMachine_result(VBoxProxyView* proxy, BSTR settingsFile, BSTR password, IUnknown** ppMachine) {
    IUnknown* realVBox = proxy->realVBox;
    if (!realVBox || !ppMachine) return E_POINTER;
    *ppMachine = NULL;
    void* vtbl = *(void**)realVBox;
    HRESULT (__stdcall *realOpen)(IUnknown*, BSTR, BSTR, IUnknown**) =
        (HRESULT (__stdcall*)(IUnknown*, BSTR, BSTR, IUnknown**))((void**)vtbl)[39];
    HRESULT hr = realOpen(realVBox, settingsFile, password, ppMachine);
    if (SUCCEEDED(hr) && *ppMachine) {
        MachineProxy* mp = create_machine_proxy(*ppMachine);
        if (mp) *ppMachine = (IUnknown*)mp;
    }
    return hr;
}

// For later: registerMachine, cloneMachine, etc.
extern "C" HRESULT __stdcall wrap_registerMachine_result(VBoxProxyView* proxy, IUnknown* machine) {
    IUnknown* realVBox = proxy->realVBox;
    if (!realVBox) return E_POINTER;
    void* vtbl = *(void**)realVBox;
    HRESULT (__stdcall *realReg)(IUnknown*, IUnknown*) =
        (HRESULT (__stdcall*)(IUnknown*, IUnknown*))((void**)vtbl)[40];
    return realReg(realVBox, machine);
}

// IMachine vtable & mapping (VBox5.2 -> VBox7.2 translation)
// The vtable entries are 175 ASM thunks (im_e_0..im_e_174) from imachine_entries.asm
extern "C" {
    void im_e_0(void);
    void im_e_1(void);
    void im_e_2(void);
    void im_e_3(void);
    void im_e_4(void);
    void im_e_5(void);
    void im_e_6(void);
    void im_e_7(void);
    void im_e_8(void);
    void im_e_9(void);
    void im_e_10(void);
    void im_e_11(void);
    void im_e_12(void);
    void im_e_13(void);
    void im_e_14(void);
    void im_e_15(void);
    void im_e_16(void);
    void im_e_17(void);
    void im_e_18(void);
    void im_e_19(void);
    void im_e_20(void);
    void im_e_21(void);
    void im_e_22(void);
    void im_e_23(void);
    void im_e_24(void);
    void im_e_25(void);
    void im_e_26(void);
    void im_e_27(void);
    void im_e_28(void);
    void im_e_29(void);
    void im_e_30(void);
    void im_e_31(void);
    void im_e_32(void);
    void im_e_33(void);
    void im_e_34(void);
    void im_e_35(void);
    void im_e_36(void);
    void im_e_37(void);
    void im_e_38(void);
    void im_e_39(void);
    void im_e_40(void);
    void im_e_41(void);
    void im_e_42(void);
    void im_e_43(void);
    void im_e_44(void);
    void im_e_45(void);
    void im_e_46(void);
    void im_e_47(void);
    void im_e_48(void);
    void im_e_49(void);
    void im_e_50(void);
    void im_e_51(void);
    void im_e_52(void);
    void im_e_53(void);
    void im_e_54(void);
    void im_e_55(void);
    void im_e_56(void);
    void im_e_57(void);
    void im_e_58(void);
    void im_e_59(void);
    void im_e_60(void);
    void im_e_61(void);
    void im_e_62(void);
    void im_e_63(void);
    void im_e_64(void);
    void im_e_65(void);
    void im_e_66(void);
    void im_e_67(void);
    void im_e_68(void);
    void im_e_69(void);
    void im_e_70(void);
    void im_e_71(void);
    void im_e_72(void);
    void im_e_73(void);
    void im_e_74(void);
    void im_e_75(void);
    void im_e_76(void);
    void im_e_77(void);
    void im_e_78(void);
    void im_e_79(void);
    void im_e_80(void);
    void im_e_81(void);
    void im_e_82(void);
    void im_e_83(void);
    void im_e_84(void);
    void im_e_85(void);
    void im_e_86(void);
    void im_e_87(void);
    void im_e_88(void);
    void im_e_89(void);
    void im_e_90(void);
    void im_e_91(void);
    void im_e_92(void);
    void im_e_93(void);
    void im_e_94(void);
    void im_e_95(void);
    void im_e_96(void);
    void im_e_97(void);
    void im_e_98(void);
    void im_e_99(void);
    void im_e_100(void);
    void im_e_101(void);
    void im_e_102(void);
    void im_e_103(void);
    void im_e_104(void);
    void im_e_105(void);
    void im_e_106(void);
    void im_e_107(void);
    void im_e_108(void);
    void im_e_109(void);
    void im_e_110(void);
    void im_e_111(void);
    void im_e_112(void);
    void im_e_113(void);
    void im_e_114(void);
    void im_e_115(void);
    void im_e_116(void);
    void im_e_117(void);
    void im_e_118(void);
    void im_e_119(void);
    void im_e_120(void);
    void im_e_121(void);
    void im_e_122(void);
    void im_e_123(void);
    void im_e_124(void);
    void im_e_125(void);
    void im_e_126(void);
    void im_e_127(void);
    void im_e_128(void);
    void im_e_129(void);
    void im_e_130(void);
    void im_e_131(void);
    void im_e_132(void);
    void im_e_133(void);
    void im_e_134(void);
    void im_e_135(void);
    void im_e_136(void);
    void im_e_137(void);
    void im_e_138(void);
    void im_e_139(void);
    void im_e_140(void);
    void im_e_141(void);
    void im_e_142(void);
    void im_e_143(void);
    void im_e_144(void);
    void im_e_145(void);
    void im_e_146(void);
    void im_e_147(void);
    void im_e_148(void);
    void im_e_149(void);
    void im_e_150(void);
    void im_e_151(void);
    void im_e_152(void);
    void im_e_153(void);
    void im_e_154(void);
    void im_e_155(void);
    void im_e_156(void);
    void im_e_157(void);
    void im_e_158(void);
    void im_e_159(void);
    void im_e_160(void);
    void im_e_161(void);
    void im_e_162(void);
    void im_e_163(void);
    void im_e_164(void);
    void im_e_165(void);
    void im_e_166(void);
    void im_e_167(void);
    void im_e_168(void);
    void im_e_169(void);
    void im_e_170(void);
    void im_e_171(void);
    void im_e_172(void);
    void im_e_173(void);
    void im_e_174(void);
    void thunk_QI(void);   void thunk_AR(void);   void thunk_RL(void);
    void thunk_clone_check(void);   // vtable[1]: 3-arg clone precondition probe (ret 0xc)
    void thunk_pop2_4(void);        // wrapper[4]: E_FAIL probe, consumes 1 dword
    void thunk_pop2_6(void);        // wrapper[5]: S_OK probe,    consumes 2 dwords
    void thunk_pop2_7(void);        // wrapper[6]: S_OK probe,    consumes 1 dword
    void thunk_0(void);    void thunk_1(void);    void thunk_2(void);
    void thunk_3(void);    void thunk_4(void);    void thunk_5(void);
    void thunk_6(void);    void thunk_7(void);    void thunk_8(void);
    void thunk_9(void);    void thunk_10(void);   void thunk_11(void);
    void thunk_12(void);   void thunk_13(void);   void thunk_14(void);
    void thunk_15(void);   void thunk_16(void);   void thunk_17(void);
    void thunk_18(void);   void thunk_19(void);   void thunk_20(void);
    void thunk_21(void);   void thunk_22(void);   void thunk_23(void);
    void thunk_24(void);   void thunk_25(void);   void thunk_26(void);
    void thunk_27(void);   void thunk_28(void);   void thunk_29(void);
    void thunk_30(void);   void thunk_31(void);   void thunk_32(void);
    void thunk_33(void);   void thunk_34(void);   void thunk_35(void);
    void thunk_36(void);   void thunk_37(void);   void thunk_38(void);
    void thunk_39(void);   void thunk_40(void);   void thunk_41(void);
    void thunk_42(void);   void thunk_43(void);   void thunk_44(void);
    void thunk_45(void);   void thunk_46(void);   void thunk_47(void);
    void thunk_48(void);   void thunk_49(void);
    void spoof_get_version(void); void spoof_get_versionNormalized(void); void spoof_get_revision(void);
    void spoof_get_packageType(void);
    void sub_proxy_dispatch(void);
}

// ===== VTable =====
const void* g_vbox52_vtable[] = {
    (void*)&thunk_QI,         // [0]  QueryInterface
    (void*)&thunk_clone_check, // [1] clone precondition probe (ret 0xc) -- NOT AddRef; this is eNSP's only call
    (void*)&thunk_RL,         // [2]  Release
    // [3]-[6]: reached ONLY by NGFW_Plugin.dll (eNSP itself calls just [1] on this
    // object). The genuine VBox52.dll GetVBoxInstance object implements these as
    // forwarding getters that take ONE out-param:
    //   [3] -> realVBox[7]  get_APIVersion        plain forward, raw HRESULT
    //   [4] -> realVBox[7]  get_APIVersion        returns the BSTR, E_FAIL if null
    //   [5] -> realVBox[9]->[8]->[10]             chained
    //   [6] -> realVBox[10]->[7]->[9]             chained
    // The old stubs were bare `xor eax,eax; ret`: they never read the argument and
    // never wrote the out-param. Every caller pre-builds an out-param slot first
    // (FUN_1000dbe0 @0x1000DD57 / @0x1000DE3C, FUN_1000df70 @0x1000DF95), so the
    // stub also left the stack misaligned relative to what the caller expected.
    // FUN_1000dbe0 addresses its locals esp-relative with NO frame pointer (ebp holds
    // the CVBoxWrapper), so a misaligned esp made it read the wrong slot, pick up a
    // CString whose data pointer was NULL, and die in CloneData(0 - 0x10) reading
    // 0xFFFFFFF0.
    // UNI_THUNK_DIAG tail-jumps: it only swaps `this` for realVBox and leaves the
    // arguments untouched, so the real method's own ret N cleans the stack exactly
    // as it does for the genuine wrapper.
    (void*)&thunk_4,      // [3]  -> realVBox[11] get_APIVersion        (genuine: realVBox[7])
    (void*)&thunk_pop2_4, // [4]  E_FAIL probe -> the negative FUN_1000dbe0 needs
    (void*)&thunk_pop2_6, // [5]  S_OK probe   -> FUN_1000e870 needs non-negative
    (void*)&thunk_pop2_7, // [6]  S_OK probe   -> FUN_1000dfb0 only checks "< 0"
    (void*)&thunk_4,      // [7]  get_APIVersion         -> VBox[11]
    (void*)&thunk_5,      // [8]  get_APIRevision        -> VBox[12]
    (void*)&thunk_6,      // [9]  get_homeFolder         -> VBox[13]
    (void*)&thunk_7,      // [10] get_settingsFilePath   -> VBox[14]
    (void*)&thunk_8,      // [11] get_host               -> VBox[15]
    (void*)&thunk_9,      // [12] get_systemProperties   -> VBox[16]
    (void*)&thunk_10,     // [13] get_machines           -> VBox[17]
    (void*)&thunk_11,     // [14] get_machineGroups      -> VBox[18]
    (void*)&thunk_12,     // [15] get_hardDisks          -> VBox[19]
    (void*)&thunk_13,     // [16] get_DVDImages          -> VBox[20]
    (void*)&thunk_14,     // [17] get_floppyImages       -> VBox[21]
    (void*)&thunk_15,     // [18] get_progressOperations  -> VBox[22]
    (void*)&thunk_16,     // [19] get_guestOSTypes       -> VBox[23]
    (void*)&thunk_17,     // [20] get_sharedFolders      -> VBox[25]
    (void*)&thunk_18,     // [21] get_performanceCollector -> VBox[26]
    (void*)&thunk_19,     // [22] get_DHCPServers        -> VBox[27]
    (void*)&thunk_20,     // [23] get_NATNetworks        -> VBox[28]
    (void*)&thunk_21,     // [24] get_eventSource        -> VBox[29]
    (void*)&thunk_22,     // [25] get_extensionPackManager -> VBox[30]
    (void*)&thunk_23,     // [26] get_internalNetworks   -> VBox[31]
    (void*)&thunk_24,     // [27] get_genericNetworkDrivers -> VBox[33]
    (void*)&thunk_25,     // [28] composeMachineFilename  -> VBox[36]
    (void*)&thunk_26,     // [29] createAppliance         -> VBox[44]
    (void*)&thunk_27,     // [30] createDHCPServer        -> VBox[57]
    (void*)&thunk_28,     // [31] createMachine           -> VBox[38]
    (void*)&thunk_29,     // [32] createMedium            -> VBox[46]
    (void*)&thunk_30,     // [33] createNATNetwork        -> VBox[60]
    (void*)&thunk_31,     // [34] createSharedFolder      -> VBox[51]
    (void*)&thunk_32,     // [35] createUnattendedInstaller -> VBox[45]
    (void*)&thunk_33,     // [36] findDHCPServerByNetworkName -> VBox[58]
    (void*)&thunk_34,     // [37] findMachine             -> VBox[41]
    (void*)&thunk_35,     // [38] findNATNetworkByName    -> VBox[61]
    (void*)&thunk_36,     // [39] getExtraData            -> VBox[54]
    (void*)&thunk_37,     // [40] getExtraDataKeys        -> VBox[53]
    (void*)&thunk_38,     // [41] getGuestOSType          -> VBox[48]
    (void*)&thunk_39,     // [42] getMachineStates        -> VBox[43]
    (void*)&thunk_40,     // [43] getMachinesByGroups     -> VBox[42]
    (void*)&thunk_41,     // [44] openMachine             -> VBox[39]
    (void*)&thunk_42,     // [45] openMedium              -> VBox[47]
    (void*)&thunk_43,     // [46] registerMachine         -> VBox[40]
    (void*)&thunk_44,     // [47] removeDHCPServer        -> VBox[59]
    (void*)&thunk_45,     // [48] removeNATNetwork        -> VBox[62]
    (void*)&thunk_46,     // [49] removeSharedFolder      -> VBox[52]
    (void*)&thunk_47,     // [50] setExtraData            -> VBox[55]
    (void*)&thunk_48,     // [51] setSettingsSecret       -> VBox[56]
    (void*)&thunk_49,     // [52] checkFirmwarePresent    -> VBox[70]
};

// ===== DllMain =====
BOOL WINAPI DllMain(HINSTANCE h, DWORD r, LPVOID) {
    if (r == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(h);
        InitializeCriticalSection(&g_proxy_lock);
        AddVectoredExceptionHandler(TRUE, CrashVEH);
        // Pin ourselves in memory for the process lifetime. ngfw's CVBoxWrapper dtor
        // (FUN_1000c840) calls FreeLibrary(VBox52) after its clone-precondition probe.
        // But we install a PROCESS-GLOBAL vectored exception handler (CrashVEH) and hand
        // out proxy objects whose vtables/thunks live in OUR code. If FreeLibrary actually
        // unmapped us, the still-registered CrashVEH (and any live proxy vtable) would point
        // into freed address space -> the next exception invokes the dangling VEH ->
        // access violation -> re-enters the VEH -> KiUserExceptionDispatcher/RtlUnwind
        // recursion -> stack overflow (observed: crash at <Unloaded_VBox52.dll>+0x15c0).
        // Pinning makes ngfw's FreeLibrary a no-op (ref never hits 0); consistent with our
        // DllCanUnloadNow=S_FALSE "never unload" intent.
        HMODULE self = NULL;
        GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                           (LPCWSTR)&DllMain, &self);
    }
    return TRUE;
}

// ===== CoGetClassObject hook =====
typedef HRESULT (__stdcall *PFN_CoGetClassObject)(REFCLSID rclsid, DWORD dwContext, LPVOID pvReserved, REFIID riid, LPVOID *ppv);
static void install_iat_hook();
static PFN_CoGetClassObject g_real_CoGetClassObject = NULL;
static volatile LONG g_factory_guard = 0;

// Simple IClassFactory that returns our proxy for CLSID_VirtualBox
// CRITICAL: IUnknown methods on x86 __stdcall MUST take explicit this param,
// otherwise the compiler emits ret 0 (no stack cleanup) while COM pushes this
// onto the stack, causing stack imbalance and a downstream crash in combase.dll.
static ULONG __stdcall Factory_AddRef(void* this_) { (void)this_; DBG("[Factory] AddRef"); return 2; }
static ULONG __stdcall Factory_Release(void* this_) { (void)this_; DBG("[Factory] Release"); return 1; }
static HRESULT __stdcall Factory_QI(void* this_, REFIID riid, void** ppv) {
    DBG("[Factory] QI this=%p", this_);
    if (!ppv) return E_POINTER;
    *ppv = this_;
    return S_OK;
}

// Create our proxy by loading VBoxC.dll directly (avoids recursion via InprocServer32)
static HRESULT __stdcall Factory_CreateInstance(void* this_, IUnknown* outer, REFIID riid, void** ppv) {
    if (outer) return CLASS_E_NOAGGREGATION;
    DBG("[Factory] CreateInstance called");

    // Load VBoxC.dll directly to get the real class factory
    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    DBG("[Factory] CoInitializeEx: 0x%08lX", hr);

    // Use CoCreateInstance with CLSCTX_LOCAL_SERVER to bypass our InprocServer32
    IUnknown* realVBox = NULL;
    hr = CoCreateInstance(CLSID_VirtualBox, NULL,
        CLSCTX_LOCAL_SERVER,  // Forces LocalServer32 (VBoxSVC), not our InprocServer32
        IID_VBox7_IVirtualBox, (void**)&realVBox);
    if (FAILED(hr)) {
        DBG("[Factory] CoCreateInstance failed: 0x%08lX", hr);
        return hr;
    }

    // Create our proxy wrapping the real VBox
    VBoxProxyRoot* root = (VBoxProxyRoot*)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(VBoxProxyRoot));
    if (!root) { realVBox->Release(); return E_OUTOFMEMORY; }
    root->refCount = 1;
    root->view.vtable = g_vbox52_vtable;
    root->view.self1 = NULL;   // original Huawei wrapper inits these to NULL
    root->view.self2 = NULL;   // spoof setter/clearer (vtable[3..6]) manages them
    root->view.realVBox = realVBox;
    VBoxProxyView* proxy = &root->view;
    g_cached_proxy = proxy;
    register_proxy(proxy);
    install_iat_hook();

    DBG("[Factory] proxy=%p realVBox=%p", proxy, realVBox);

    // Return the proxy for the requested IID
    *ppv = proxy;
    return S_OK;
}
static HRESULT __stdcall Factory_LockServer(void* this_, BOOL lock) { return S_OK; }

static const DWORD g_factory_vtable[] = {
    (DWORD)Factory_QI, (DWORD)Factory_AddRef, (DWORD)Factory_Release,
    (DWORD)Factory_CreateInstance, (DWORD)Factory_LockServer
};
static struct { const DWORD* vtbl; } g_factory = { g_factory_vtable };

static HRESULT __stdcall CoGetClassObjectHook(REFCLSID rclsid, DWORD dwContext, LPVOID pvReserved, REFIID riid, LPVOID *ppv) {
    DBG("[Hook] CoGetClassObject: CLSID={%08lX-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X} ctx=0x%lX",
        rclsid.Data1, rclsid.Data2, rclsid.Data3,
        rclsid.Data4[0], rclsid.Data4[1], rclsid.Data4[2], rclsid.Data4[3],
        rclsid.Data4[4], rclsid.Data4[5], rclsid.Data4[6], rclsid.Data4[7],
        dwContext);

    // Intercept CLSID_VirtualBox: return our proxy factory instead of VBox 7.2.8
    if (!g_factory_guard && memcmp(&rclsid, &CLSID_VirtualBox, sizeof(CLSID)) == 0) {
        g_factory_guard = 1;
        DBG("[Hook] CLSID_VirtualBox intercepted -> returning proxy factory");
        *ppv = &g_factory;
        return S_OK;
    }

    return g_real_CoGetClassObject(rclsid, dwContext, pvReserved, riid, ppv);
}

// CreateProcessW hook — entry-point detour on kernel32!CreateProcessW.
// Catches ALL callers in the process (eNSP_VBoxServer.exe + NGFW_Plugin.dll),
// which IAT hooking cannot do (NGFW has its own IAT entry).
//
// UART2 injection: NGFW sends "modifyvm <vm> --uartmode2 server <pipe>" WITHOUT
// first enabling UART2. In VBox 7.2, UART2 defaults to disabled, so --uartmode2
// has no effect and VBoxHeadless never creates the named pipe. We fix this by
// modifying the command line to insert "--uart2 0x2F8 3" before "--uartmode2",
// making it a single modifyvm call: "modifyvm <vm> --uart2 0x2F8 3 --uartmode2 server <pipe>".
//
// NO synchronous wait: NGFW uses WaitForSingleObject(hProcess, 30000) on the
// returned handle. If we block in the hook, NGFW's timer fires and it kills
// the process. We return immediately after CreateProcessW so NGFW controls timing.
typedef BOOL (__stdcall *PFN_CreateProcessW)(LPCWSTR, LPWSTR, LPSECURITY_ATTRIBUTES, LPSECURITY_ATTRIBUTES,
    BOOL, DWORD, LPVOID, LPCWSTR, LPSTARTUPINFOW, LPPROCESS_INFORMATION);
static PFN_CreateProcessW g_real_CreateProcessW = NULL;
static BYTE g_original_bytes[5] = {0};
static bool g_detour_installed = false;

// Log app + cmd using WideCharToMultiByte (sprintf %S is unreliable for complex strings).
static void log_createprocess(LPCWSTR app, LPCWSTR cmd) {
    char abuf[260] = {0}, cbuf[1024] = {0};
    if (app) WideCharToMultiByte(CP_ACP, 0, app, -1, abuf, sizeof(abuf)-1, NULL, NULL);
    if (cmd) WideCharToMultiByte(CP_ACP, 0, cmd, -1, cbuf, sizeof(cbuf)-1, NULL, NULL);
    char line[1400]; int n = sprintf(line, "%lu [VBox52:CreateProcessW] app='%s' cmd='%s'",
        GetTickCount(), abuf, cbuf);
    char wlog[MAX_PATH];
    if (GetLogPath(wlog, sizeof(wlog), "vboxmanage_wrapper.log")) {
        FILE* f = fopen(wlog, "a");
        if (f) { fprintf(f, "%s\n", line); fclose(f); }
    }
    DBG("[Hook] CreateProcessW: app='%s' cmd='%s'", abuf, cbuf);
}

// If cmd is a modifyvm with --uartmode2 but no --uart2, inject native UART2 enable only.
// 实测确认：clonevm 已正确继承模板的 longmode/apic/ioapic/chipset 配置，
// 注入 CPU 选项反而触发 VBox 7.2 "Limiting firmware APIC" 逻辑导致启动失败。
// 只需确保 uart2 (COM2, 0x2F8) 启用，eNSP 才能读到管道上的私有协议数据。
// Returns a new alloc'd wide string (caller frees) or NULL (no modification needed).
static LPWSTR inject_vm_config(LPCWSTR cmd) {
    if (!cmd) return NULL;
    if (!wcsstr(cmd, L"modifyvm")) return NULL;
    const wchar_t* p_mode2 = wcsstr(cmd, L"--uartmode2");
    if (!p_mode2) return NULL;
    if (wcsstr(cmd, L"--uart2")) return NULL;
    // Native uart2 enable only (space-separated IO base IRQ, per VBox 7.2 syntax)
    const wchar_t* insert = L" --uart2 0x2f8 3 ";
    size_t prefix_len = p_mode2 - cmd;
    size_t insert_len = wcslen(insert);
    size_t suffix_len = wcslen(p_mode2);
    size_t total = prefix_len + insert_len + suffix_len + 1;
    LPWSTR modified = (LPWSTR)HeapAlloc(GetProcessHeap(), 0, total * sizeof(wchar_t));
    if (!modified) return NULL;
    memcpy(modified, cmd, prefix_len * sizeof(wchar_t));
    memcpy(modified + prefix_len, insert, insert_len * sizeof(wchar_t));
    wcscpy(modified + prefix_len + insert_len, p_mode2);
    DBG("[Hook] VM config injected: '%S'", modified);
    return modified;
}

static BOOL __stdcall CreateProcessWHook(LPCWSTR app, LPWSTR cmd, LPSECURITY_ATTRIBUTES pa,
    LPSECURITY_ATTRIBUTES ta, BOOL ih, DWORD flags, LPVOID env, LPCWSTR dir,
    LPSTARTUPINFOW si, LPPROCESS_INFORMATION pi) {
    // Log the call (both app and cmd)
    log_createprocess(app, cmd);

    // Inject full VM config (longmode/apic/chipset/uart swap) if needed
    LPWSTR modified_cmd = inject_vm_config(cmd);
    LPWSTR exec_cmd = modified_cmd ? modified_cmd : cmd;

    // Uninstall detour to call the real function (brief window; acceptable
    // since we no longer block — the race only risks missing a hook log, not
    // a crash).
    DWORD oldProtect;
    VirtualProtect((LPVOID)g_real_CreateProcessW, 5, PAGE_EXECUTE_READWRITE, &oldProtect);
    memcpy((LPVOID)g_real_CreateProcessW, g_original_bytes, 5);
    VirtualProtect((LPVOID)g_real_CreateProcessW, 5, oldProtect, &oldProtect);
    BOOL result = g_real_CreateProcessW(app, exec_cmd, pa, ta, ih, flags, env, dir, si, pi);
    // Re-install detour
    VirtualProtect((LPVOID)g_real_CreateProcessW, 5, PAGE_EXECUTE_READWRITE, &oldProtect);
    BYTE jmp[5] = { 0xE9, 0,0,0,0 };
    *(DWORD*)(jmp+1) = (DWORD)(DWORD_PTR)CreateProcessWHook - (DWORD)(DWORD_PTR)g_real_CreateProcessW - 5;
    memcpy((LPVOID)g_real_CreateProcessW, jmp, 5);
    VirtualProtect((LPVOID)g_real_CreateProcessW, 5, oldProtect, &oldProtect);

    // NO synchronous wait — NGFW controls process lifetime via its own WaitForSingleObject.
    if (modified_cmd) HeapFree(GetProcessHeap(), 0, modified_cmd);
    return result;
}

static void install_iat_hook() {
    if (g_detour_installed) return;
    HMODULE hK32 = GetModuleHandleA("kernel32.dll");
    if (!hK32) return;
    g_real_CreateProcessW = (PFN_CreateProcessW)GetProcAddress(hK32, "CreateProcessW");
    if (!g_real_CreateProcessW) return;
    // Save original bytes
    memcpy(g_original_bytes, g_real_CreateProcessW, 5);
    // Install detour: jmp offset = target - source - 5
    BYTE jmp[5] = { 0xE9, 0,0,0,0 };
    *(DWORD*)(jmp+1) = (DWORD)(DWORD_PTR)CreateProcessWHook - (DWORD)(DWORD_PTR)g_real_CreateProcessW - 5;
    DWORD oldProtect;
    VirtualProtect((LPVOID)g_real_CreateProcessW, 5, PAGE_EXECUTE_READWRITE, &oldProtect);
    memcpy((LPVOID)g_real_CreateProcessW, jmp, 5);
    VirtualProtect((LPVOID)g_real_CreateProcessW, 5, oldProtect, &oldProtect);
    g_detour_installed = true;
    DBG("[Hook] CreateProcessW detour installed: original=%p patch=%p", g_real_CreateProcessW, CreateProcessWHook);

    // Also hook CoGetClassObject via IAT (already works for exe; ngfw may call via COM)
    HMODULE hExe = GetModuleHandleA(NULL);
    if (!hExe) return;
    PBYTE base = (PBYTE)hExe;
    PIMAGE_DOS_HEADER dos = (PIMAGE_DOS_HEADER)base;
    PIMAGE_NT_HEADERS nt = (PIMAGE_NT_HEADERS)(base + dos->e_lfanew);
    if (nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].Size == 0) return;
    PIMAGE_IMPORT_DESCRIPTOR imports = (PIMAGE_IMPORT_DESCRIPTOR)(base + nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress);
    for (; imports->Name && imports->OriginalFirstThunk; imports++) {
        const char* dllName = (const char*)(base + imports->Name);
        PIMAGE_THUNK_DATA iatThunk = (PIMAGE_THUNK_DATA)(base + imports->FirstThunk);
        PIMAGE_THUNK_DATA intThunk = (PIMAGE_THUNK_DATA)(base + imports->OriginalFirstThunk);
        for (; intThunk->u1.AddressOfData; intThunk++, iatThunk++) {
            if (IMAGE_SNAP_BY_ORDINAL(intThunk->u1.Ordinal)) continue;
            PIMAGE_IMPORT_BY_NAME importByName = (PIMAGE_IMPORT_BY_NAME)(base + intThunk->u1.AddressOfData);
            const char* fname = (const char*)importByName->Name;
            if (_stricmp(dllName, "ole32.dll") == 0 && strcmp(fname, "CoGetClassObject") == 0) {
                g_real_CoGetClassObject = (PFN_CoGetClassObject)iatThunk->u1.Function;
                DWORD oldProtect2;
                VirtualProtect(&iatThunk->u1.Function, sizeof(void*), PAGE_READWRITE, &oldProtect2);
                iatThunk->u1.Function = (DWORD_PTR)CoGetClassObjectHook;
                VirtualProtect(&iatThunk->u1.Function, sizeof(void*), oldProtect2, &oldProtect2);
                DBG("[Hook] CoGetClassObject IAT hooked: original=%p", g_real_CoGetClassObject);
                break;
            }
        }
    }
    if (!g_real_CoGetClassObject) DBG("[Hook] CoGetClassObject IAT hook FAILED");
}

// ===== Exports =====
extern "C" __declspec(dllexport)
void* __stdcall GetVBoxInstance() {
    DBG("[VBox52] GetVBoxInstance called (FULL)");
    HRESULT hrCo = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    DBG("[VBox52] CoInitializeEx: 0x%08lX", hrCo);

    IUnknown* realVBox = NULL;
    HRESULT hr = CoCreateInstance(CLSID_VirtualBox, NULL,
        CLSCTX_LOCAL_SERVER,
        IID_VBox7_IVirtualBox, (void**)&realVBox);
    if (FAILED(hr)) {
        DBG("[VBox52] CoCreateInstance failed: 0x%08lX", hr);
        return NULL;
    }

    VBoxProxyRoot* root = (VBoxProxyRoot*)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(VBoxProxyRoot));
    if (!root) { realVBox->Release(); return NULL; }
    root->refCount = 1;
    root->view.vtable = g_vbox52_vtable;
    root->view.self1 = NULL;   // original Huawei wrapper inits these to NULL
    root->view.self2 = NULL;   // spoof setter/clearer (vtable[3..6]) manages them
    root->view.realVBox = realVBox;
    VBoxProxyView* proxy = &root->view;
    g_cached_proxy = proxy;
    register_proxy(proxy);
    install_iat_hook();

    DBG("[VBox52] GetVBoxInstance done: proxy=%p realVBox=%p", proxy, realVBox);
    return (void*)proxy;
}

extern "C" __declspec(dllexport)
void __stdcall DelVBoxInstance(void) {
    // Genuine Huawei VBox52.DelVBoxInstance is a NO-ARG export: ngfw's CVBoxWrapper
    // dtor (FUN_1000c840) does GetProcAddress("DelVBoxInstance"); call eax with ZERO
    // args pushed, then FreeLibrary. Our old `void* p` signature read a stale stack
    // slot as the instance ptr (garbage, e.g. 0xF05BEDCD) -> deref crash, and its
    // `ret 4` popped a dword the caller never pushed -> corrupted ngfw's stack.
    // Operate on the singleton cached by GetVBoxInstance instead of a passed arg.
    void* p = g_cached_proxy;
    DBG("[VBox52] DelVBoxInstance() cached=%p", p);
    if (!p) return;
    VBoxProxyView* proxy = (VBoxProxyView*)p;
    VBoxProxyRoot* root = (VBoxProxyRoot*)((char*)proxy - 4);
    EnterCriticalSection(&g_proxy_lock);
    for (ProxyEntry** pp = &g_proxy_list; *pp; pp = &(*pp)->next) {
        if ((*pp)->proxy == proxy) {
            ProxyEntry* tmp = *pp;
            *pp = (*pp)->next;
            HeapFree(GetProcessHeap(), 0, tmp);
            break;
        }
    }
    LeaveCriticalSection(&g_proxy_lock);
    if (root->view.realVBox) root->view.realVBox->Release();
    HeapFree(GetProcessHeap(), 0, root);
    g_cached_proxy = NULL;
}

// ===== COM in-process server exports =====
// Use pragma to export (avoids conflict with combaseapi.h declarations)
#pragma comment(linker, "/export:DllGetClassObject=_DllGetClassObject@12")
#pragma comment(linker, "/export:DllCanUnloadNow=_DllCanUnloadNow@0")

extern "C" HRESULT __stdcall DllGetClassObject(REFCLSID rclsid, REFIID riid, void** ppv) {
    if (memcmp(&rclsid, &CLSID_VirtualBox, sizeof(CLSID)) != 0) return CLASS_E_CLASSNOTAVAILABLE;
    DBG("[COM] DllGetClassObject(CLSID_VirtualBox)");
    if (memcmp(&riid, &IID_IClassFactory, sizeof(IID)) != 0 &&
        memcmp(&riid, &IID_IUnknown_, sizeof(IID)) != 0) return E_NOINTERFACE;
    *ppv = &g_factory;
    return S_OK;
}

extern "C" HRESULT __stdcall DllCanUnloadNow() {
    return S_FALSE;
}
