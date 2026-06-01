# eNSP VBox52.dll Proxy Calling Convention Analysis

## Executive Summary

This report documents the exact mechanism by which eNSP Client and VBoxServer call methods on the VBox52.dll proxy object returned by `GetVBoxInstance()`. The analysis is based on static reverse engineering of both `eNSP_Client.exe` and `eNSP_VBoxServer.exe` using Capstone disassembly and pefile PE parsing.

---

## Key Findings

1. **Direct COM-style vtable dispatch** -- eNSP does NOT use IDispatch. It dereferences the proxy pointer to obtain a vtable and calls methods by numeric offset.

2. **Four custom methods used by eNSP_Client.exe** -- at vtable offsets 0x0C, 0x10, 0x14, 0x18 (method indices 3, 4, 5, 6).

3. **No QueryInterface on the proxy** -- eNSP never calls QI (vtable+0x00) on the proxy interface.

4. **Call pattern is `call reg`, NOT `call [reg+offset]`** -- The function pointer is loaded into a register first, then called indirectly. There are zero instances of `call [reg+offset]` in either binary.

5. **VBoxServer uses C++ wrapper (CVBoxWrapper)** -- Only calls AddRef on the proxy pointer directly; actual method calls go through the wrapper class.

6. **STA COM model** -- Both binaries use `CoInitialize(NULL)`, not `CoInitializeEx`.

7. **Return value check** -- All proxy methods return an HRESULT-like value tested with `test eax, eax; jge` or `jl` (signed comparison).

---

## 1. Proxy Loading Mechanism

Both executables use `LoadLibraryW` + `GetProcAddress` to dynamically load VBox52.dll and obtain the `GetVBoxInstance` export.

### eNSP_Client.exe

```
Address        Instruction                          Notes
0x0047FCCF:    call [KERNEL32.dll!LoadLibraryW]     Load VBox52.dll
0x0047FD2D:    mov dword ptr [0x5F5288], eax       Store HMODULE
0x0047FD40:    push 0x5AC098                        "GetVBoxInstance"
0x0047FD45:    push eax                             HMODULE
0x0047FD46:    call [KERNEL32.dll!GetProcAddress]   Get function ptr
0x0047FD4C:    test eax, eax
0x0047FD4E:    jne 0x47FD9A                         If found, jump
0x0047FD9A:    call eax                             Call GetVBoxInstance()
0x0047FD9C:    test eax, eax
0x0047FD9E:    mov dword ptr [0x5F528C], eax        Store proxy ptr
```

- **Module handle stored at:** `[0x005F5288]`
- **Proxy pointer stored at:** `[0x005F528C]`

### eNSP_VBoxServer.exe

```
Address        Instruction                          Notes
0x00414BAC:    call [KERNEL32.dll!LoadLibraryW]     Load VBox52.dll
0x00414BB4:    mov dword ptr [0x474488], eax        Store HMODULE
0x00414C25:    push 0x462B8C                        "GetVBoxInstance"
0x00414C2A:    push eax                             HMODULE
0x00414C2B:    call [KERNEL32.dll!GetProcAddress]   Get function ptr
0x00414C31:    test eax, eax
0x00414C33:    jne 0x414C67                         If found, jump
0x00414C67:    call eax                             Call GetVBoxInstance()
0x00414C69:    test eax, eax
0x00414C6B:    mov dword ptr [0x47448C], eax        Store proxy ptr
```

- **Module handle stored at:** `[0x00474488]`
- **Proxy pointer stored at:** `[0x0047448C]` (NOT `[0x0047484C]` -- earlier documentation had a typo)

---

## 2. Calling Pattern

**CRITICAL FINDING:** eNSP uses `call reg` pattern, NOT `call [reg+offset]`. There are zero `call [reg+offset]` instructions in either binary. All indirect calls through registers use `call eax`, `call edx`, etc.

### The three-step dispatch sequence:

```
Step 1: mov reg1, dword ptr [global_ptr]     Load proxy interface pointer
Step 2: mov reg2, dword ptr [reg1]           Dereference -> vtable pointer
Step 3: mov reg3, dword ptr [reg2 + offset]  Load function pointer from vtable
Step 4: call reg3                            Call function
```

### Concrete example from eNSP_Client.exe (vtable+0x0C):

```
0x0048060B:  mov ecx, dword ptr [0x5F528C]    ; Load proxy ptr
0x00480611:  mov eax, dword ptr [ecx]          ; Dereference -> vtable
0x00480613:  mov edx, dword ptr [eax + 0x0C]   ; Load vtable[3] function ptr
0x00480616:  call edx                           ; Call method
0x00480618:  test eax, eax                      ; Check HRESULT
0x0048061A:  jl 0x4805AA                        ; Jump if failed (signed)
```

---

## 3. VTable Offsets Used by eNSP_Client.exe

### On the PROXY interface (traced from `[0x005F528C]`):

| Offset | Method Index | IUnknown Method | Call Sites | Description |
|--------|-------------|-----------------|------------|-------------|
| `0x00C` | `3` | Custom Method 0 | `0x480616` call edx | First custom method after IUnknown (QI=0, AR=4, RL=8) |
| `0x010` | `4` | Custom Method 1 | `0x480361` call eax | Called from function at `0x48015E` |
| `0x014` | `5` | Custom Method 2 | `0x48044E` call eax, `0x480F53` call edx | Called from two different functions |
| `0x018` | `6` | Custom Method 3 | `0x480C86` call edx | Called from function at `0x480BC2` |

### Detailed call sites:

#### vtable+0x0C (method index 3)
```
Function: 0x004805AF
0x004805AF:  mov eax, [esp+8]           ; Get parameter (enum/selector)
0x004805BB:  jmp [eax*4 + 0x480620]     ; Jump table dispatch
            ; ... switch cases push string addresses (0x5AC1F8, 0x5AC2A0, etc.)
0x00480606:  call 0x407130              ; Call string construction helper
0x0048060B:  mov ecx, [0x5F528C]        ; <<< LOAD PROXY PTR
0x00480611:  mov eax, [ecx]             ; Get vtable
0x00480613:  mov edx, [eax + 0x0C]      ; vtable[3]
0x00480616:  call edx                   ; <<< CALL
0x00480618:  test eax, eax              ; Check HRESULT
0x0048061A:  jl 0x4805AA               ; Jump if error
0x0048061C:  xor eax, eax
0x0048061E:  pop ecx
0x0048061F:  ret
```

#### vtable+0x10 (method index 4)
```
Function: 0x0048015E
0x0048034E:  mov ecx, [0x5F528C]        ; <<< LOAD PROXY PTR
0x00480359:  mov edx, [ecx]             ; Get vtable
0x0048035B:  mov eax, [edx + 0x10]      ; vtable[4]
0x0048035E:  add esp, 4                 ; Cleanup stack
0x00480361:  call eax                   ; <<< CALL
0x00480363:  test eax, eax              ; Check HRESULT
0x00480365:  jge 0x48040A              ; Jump if success
```

#### vtable+0x14 (method index 5) -- called from function 0x0048040A
```
Function: 0x0048040A
0x00480435:  mov ecx, [0x5F528C]        ; <<< LOAD PROXY PTR
0x00480441:  mov eax, [ecx]             ; Get vtable
0x00480443:  mov eax, [eax + 0x14]      ; vtable[5]
0x00480446:  add esp, 4                 ; Cleanup stack
0x0048044E:  call eax                   ; <<< CALL
0x00480450:  test eax, eax
0x00480452:  mov byte [esp+0x38], 2
0x00480457:  jl 0x4804F1               ; Jump if error
```

#### vtable+0x14 (method index 5) -- also called from function 0x00480CF4
```
Function: 0x00480CF4
0x00480F3B:  mov ecx, [0x5F528C]        ; <<< LOAD PROXY PTR
0x00480F46:  mov eax, [ecx]             ; Get vtable
0x00480F48:  mov edx, [eax + 0x14]      ; vtable[5]
0x00480F4B:  add esp, 4
0x00480F53:  call edx                   ; <<< CALL
0x00480F55:  test eax, eax
0x00480F57:  mov byte [esp+0x3C], 2
0x00480F5C:  jge 0x480FF4              ; Jump if success
```

#### vtable+0x18 (method index 6)
```
Function: 0x00480BC2
0x00480C73:  mov ecx, [0x5F528C]        ; <<< LOAD PROXY PTR
0x00480C7E:  mov eax, [ecx]             ; Get vtable
0x00480C80:  mov edx, [eax + 0x18]      ; vtable[6]
0x00480C83:  add esp, 4
0x00480C86:  call edx                   ; <<< CALL
0x00480C88:  or edx, 0xFFFFFFFF
0x00480C93:  test eax, eax
0x00480C99:  jge 0x480CC8              ; Jump if success
```

### What the vtable+0x04 calls are:
The vtable+0x04 calls that appear after each proxy method call are **AddRef/Release** on C++ smart pointer wrapper objects (not on the proxy). These use the pattern:
```
mov ecx, [esi]           ; Get vtable from wrapper object
mov edx, [ecx]           ; Get vtable
mov eax, [edx + 4]       ; vtable[1] = AddRef
push esi                 ; 'this' pointer
call eax
```
These are standard MSVC smart pointer `_com_ptr_t` AddRef patterns and are NOT proxy method calls.

---

## 4. VBoxServer Usage

VBoxServer stores the proxy pointer at `[0x0047448C]`. However, the only direct access to this global pointer is for **AddRef reference counting**. The proxy pointer is wrapped in a C++ class (`CVBoxWrapper::`).

The loading function stores the proxy:
```
0x00414BA5:  mov ecx, [0x477ADC]          ; Get path string
0x00414BAC:  call LoadLibraryW             ; Load VBox52.dll
0x00414BB4:  mov [0x474488], eax           ; Store HMODULE
0x00414C25:  push 0x462B8C                 ; "GetVBoxInstance"
0x00414C2A:  push eax
0x00414C2B:  call GetProcAddress           ; Get function
0x00414C31:  test eax, eax
0x00414C33:  jne 0x414C67
0x00414C67:  call eax                      ; GetVBoxInstance()
0x00414C69:  test eax, eax
0x00414C6B:  mov [0x47448C], eax           ; Store proxy
```

The only global pointer dereference in VBoxServer:
```
0x00414E18:  mov edx, [0x47448C]           ; Load proxy ptr
0x00414E1E:  mov eax, [edx]               ; Get vtable
0x00414E20:  add eax, 4                   ; Point to vtable[1]
0x00414E23:  mov eax, [eax]               ; Load AddRef
0x00414E2A:  mov ecx, [0x47448C]          ; Load proxy ptr again (for 'this')
0x00414E33:  call eax                     ; Call AddRef
```

VBoxServer actual VBox calls likely go through a C++ wrapper class CVBoxWrapper. The string `CVBoxWrapper::` was found in the .rdata section near the GetVBoxInstance string.

---

## 5. Calling Convention Analysis

The proxy methods use **COM stdcall convention**:

- **Parameters:** Right-to-left on the stack (standard stdcall)
- **Return value:** In `eax` (HRESULT-like, tested with signed compare: `jge`/`jl`)
- **'this' pointer:** NOT in ecx for the actual method call. The proxy ptr is loaded into ecx only as a temporary register. The actual COM convention applies: 'this' is the implicit first parameter, but from the code analysis, the proxy ptr is used to get the vtable and then the method is dispatched through a function pointer loaded from the vtable.

However, looking at the specific patterns, the calling convention seems to be:

For the `00480616` call (vtable+0x0C):
- No explicit pushes visible in the immediate vicinity before the call
- The proxy ptr IS loaded into ecx, which might serve as the 'this' pointer in MSVC's COM convention
- Alternatively, the function being called uses stdcall with all params on stack

For the `00480361` call (vtable+0x10):
- Similarly, no explicit pushes visible immediately before
- The `add esp, 4` before the call suggests stack cleanup from a previous operation

**This suggests a COM stdcall calling convention where the proxy ('this') pointer is accessible through the global variable and the function reads it from there, OR it's a C++ thiscall where ecx = this.**

Given the code pattern (ecx = proxy ptr), it is most likely **thiscall** (ecx = this pointer), not stdcall.

---

## 6. COM Apartment / Threading

| Aspect | eNSP_Client.exe | eNSP_VBoxServer.exe |
|--------|-----------------|---------------------|
| COM init | `CoInitialize(NULL)` at 0x0043B933 | `CoInitialize(NULL)` at 0x00408762 |
| COM uninit | `CoUninitialize()` at 0x0043BF2B | `CoUninitialize()` at 0x0040877F |
| Apartment | STA (single-threaded) | STA (single-threaded) |
| Ole init | `OleInitialize(NULL)` at 0x0043BF0E | Not called |

Both use `CoInitialize(NULL)` without `COINIT_MULTITHREADED`, meaning COM runs in a **Single-Threaded Apartment (STA)**. The proxy does not need to support cross-apartment marshaling.

---

## 7. String Analysis (Method Names/Hints)

In the proxy-calling functions, before the proxy dispatch, there are calls to a helper function (0x407130/0x402BE0) that takes string arguments. The strings pushed before these helper calls include:

| Address | String Content |
|---------|---------------|
| 0x5AC190 | (GUID-like, being read) |
| 0x5AC1F8 | (GUID-like, being read) |
| 0x5AC2A0 | (GUID-like, being read) |
| 0x5AC2BC | (GUID-like, being read) |
| 0x5AC3F4 | (GUID-like, being read) |
| 0x5AC410 | (GUID-like, being read) |
| 0x5AC48C | (GUID-like, being read) |
| 0x5AC49C | (GUID-like, being read) |
| 0x5AC660 | (GUID-like, being read) |
| 0x5AC6B8 | (GUID-like, being read) |
| 0x5AC768 | (GUID-like, being read) |
| 0x5AC7C8 | (GUID-like, being read) |

These strings are likely COM interface GUIDs or VirtualBox machine/VM identifiers that are passed as BSTR parameters to the VBox methods.

---

## 8. No IDispatch/QueryInterface Evidence

- **NOT a single call** to `IDispatch::GetIDsOfNames` or `IDispatch::Invoke` was found in either binary.
- **No QueryInterface** (vtable+0x00) is called on the proxy pointer chain.
- eNSP treats the proxy as a direct vtable-based COM interface, not as an IDispatch interface.

This conclusively rules out the IDispatch theory for the corrupted `this` pointer problem. The corrupted `this` pointers must be caused by a different mechanism.

---

## 9. Summary Table

| Item | eNSP_Client.exe | eNSP_VBoxServer.exe |
|------|-----------------|---------------------|
| **Image base** | 0x00400000 | 0x00400000 |
| **Module handle global** | [0x005F5288] | [0x00474488] |
| **Proxy ptr global** | [0x005F528C] | [0x0047448C] |
| **VTable dispatch** | `call reg` (not `call [reg+off]`) | `call reg` (only AddRef) |
| **Proxy vtable offsets** | 0x0C, 0x10, 0x14, 0x18 | None (wrapped in CVBoxWrapper) |
| **Custom methods** | 4 (indices 3-6) | 0 (direct) |
| **Calling convention** | stdcall/thiscall | stdcall/thiscall |
| **QueryInterface** | Not used | Not used |
| **IDispatch** | Not used | Not used |
| **COM model** | STA (CoInitialize) | STA (CoInitialize) |
| **Param setup** | Helper func 0x407130/0x402be0 | (wrapped) |
| **Return check** | test eax,eax; jge/jl | test eax,eax; jge/jl |

---

## 10. Implications for Proxy DLL

### What the proxy must support:

1. **GetVBoxInstance** must return an object whose first 4 bytes are a pointer to a vtable.

2. The vtable must have at least 7 entries (indices 0-6):
   - Index 0 (offset 0x00): QueryInterface (can stub/ignore)
   - Index 1 (offset 0x04): AddRef (must work for ref counting)
   - Index 2 (offset 0x08): Release (must work for ref counting)
   - Index 3 (offset 0x0C): Custom method -- VirtualBox API
   - Index 4 (offset 0x10): Custom method -- VirtualBox API
   - Index 5 (offset 0x14): Custom method -- VirtualBox API
   - Index 6 (offset 0x18): Custom method -- VirtualBox API

3. Methods are called via `call reg` pattern where the function pointer is loaded from vtable into a register, then called.

4. Methods return HRESULT (tested with signed comparison).

### What the proxy does NOT need:

- Full IDispatch implementation
- Type library marshaling
- Cross-apartment support
- Complex QueryInterface support

### The corrupted 'this' pointer mystery:

The corrupted `this` pointers (showing UTF-16 strings like "AR_Base", "WLAN_") are NOT caused by eNSP using IDispatch. The most likely explanations are:

1. **C++ wrapper mismatch**: The eNSP code might be compiled expecting the proxy to implement a C++ abstract class (with a specific vtable layout), but the proxy object has a different layout. When eNSP calls what it thinks is a method, the vtable offset points to wrong data.

2. **COM interface expectation**: The eNSP code might expect the proxy to implement `IVirtualBox` directly (not `IVBoxInterface`), and the vtable layout of these interfaces differs after the first few methods.

3. **Method argument mismatch**: The proxy's stub methods might use different calling conventions (cdecl vs stdcall), causing stack corruption and garbled register values.

---

## Appendix A: Analysis Methodology

- **Tool**: Capstone disassembler (x86 32-bit mode with detail)
- **PE parsing**: pefile Python library
- **Target files**:
  - `C:\Program Files\Huawei\eNSP\eNSP_Client.exe` (3.5MB, 172,814 instructions in .text)
  - `C:\Program Files\Huawei\eNSP\vboxserver\eNSP_VBoxServer.exe` (504KB, 60,048 instructions in .text)
- **Analysis date**: 2026-05-20

### Key addresses:

**eNSP_Client.exe:**
- GetVBoxInstance string: `0x005AC098`
- DelVBoxInstance string: `0x005ABF60`
- LoadLibraryW + GetProcAddress + GetVBoxInstance call: function at `0x0047FC20`
- Proxy ptr stored at: `[0x005F528C]`
- Proxy-calling functions: `0x0048015E`, `0x0048040A`, `0x004805AF`, `0x00480BC2`, `0x00480CF4`

**eNSP_VBoxServer.exe:**
- GetVBoxInstance string: `0x00462B8C`
- DelVBoxInstance string: `0x004629C4`
- LoadLibraryW + GetProcAddress + GetVBoxInstance call: function at `0x00414B97`
- Proxy ptr stored at: `[0x0047448C]` (NOT `[0x0047484C]`)
- Wrapper class: `CVBoxWrapper::` (string at `0x00462B8F` area)
