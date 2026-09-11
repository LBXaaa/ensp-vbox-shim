.386
.model flat, c
.code

; ===== VBox52.dll Thunks =====

EXTERN diag_method_call@8:PROC
EXTERN helper_QueryInterface@12:PROC
EXTERN helper_AddRef@4:PROC
EXTERN helper_Release@4:PROC
EXTERN helper_clone_check@16:PROC
EXTERN wrap_findMachine_result@12:PROC
EXTERN wrap_openMachine_result@16:PROC
EXTERN wrap_registerMachine_result@8:PROC
EXTERN ngfw_notfound@8:PROC
EXTERN ngfw_ok@8:PROC

; ===== IVirtualBox universal __stdcall thunks =====
UNI_THUNK_DIAG MACRO name, vtable_idx, diag_idx
name PROC
    push    ebx
    mov     ebx, ecx
    push    ebx
    push    diag_idx
    call    diag_method_call@8
    mov     ecx, ebx
    pop     ebx
    mov     eax, dword ptr [ecx+12]   ; eax = realVBox (was +8, then +4)
    pop     edx                      ; edx = ret_eNSP
    push    eax                      ; push realVBox as this
    push    edx                      ; push ret_eNSP
    mov     edx, dword ptr [eax]     ; edx = realVBox vtable
    jmp     dword ptr [edx+vtable_idx*4]
name ENDP
ENDM

; ===== IVirtualBox thunks (proxy[3]-[52]) =====
UNI_THUNK_DIAG thunk_0,   7,  0     ; get_version
UNI_THUNK_DIAG thunk_1,   8,  1     ; get_versionNormalized
UNI_THUNK_DIAG thunk_2,   9,  2     ; get_revision
UNI_THUNK_DIAG thunk_3,  10,  3     ; get_packageType
UNI_THUNK_DIAG thunk_4,  11,  4     ; get_APIVersion
UNI_THUNK_DIAG thunk_5,  12,  5     ; get_APIRevision
UNI_THUNK_DIAG thunk_6,  13,  6     ; get_homeFolder
UNI_THUNK_DIAG thunk_7,  14,  7     ; get_settingsFilePath
UNI_THUNK_DIAG thunk_8,  15,  8     ; get_host
UNI_THUNK_DIAG thunk_9,  16,  9     ; get_systemProperties
UNI_THUNK_DIAG thunk_10, 17, 10     ; get_machines
UNI_THUNK_DIAG thunk_11, 18, 11     ; get_machineGroups
UNI_THUNK_DIAG thunk_12, 19, 12     ; get_hardDisks
UNI_THUNK_DIAG thunk_13, 20, 13     ; get_DVDImages
UNI_THUNK_DIAG thunk_14, 21, 14     ; get_floppyImages
UNI_THUNK_DIAG thunk_15, 22, 15     ; get_progressOperations
UNI_THUNK_DIAG thunk_16, 23, 16     ; get_guestOSTypes
UNI_THUNK_DIAG thunk_17, 25, 17     ; get_sharedFolders
UNI_THUNK_DIAG thunk_18, 26, 18     ; get_performanceCollector
UNI_THUNK_DIAG thunk_19, 27, 19     ; get_DHCPServers
UNI_THUNK_DIAG thunk_20, 28, 20     ; get_NATNetworks
UNI_THUNK_DIAG thunk_21, 29, 21     ; get_eventSource
UNI_THUNK_DIAG thunk_22, 30, 22     ; get_extensionPackManager
UNI_THUNK_DIAG thunk_23, 31, 23     ; get_internalNetworks
UNI_THUNK_DIAG thunk_24, 33, 24     ; get_genericNetworkDrivers
UNI_THUNK_DIAG thunk_25, 36, 25     ; composeMachineFilename
UNI_THUNK_DIAG thunk_26, 44, 26     ; createAppliance
UNI_THUNK_DIAG thunk_27, 57, 27     ; createDHCPServer
UNI_THUNK_DIAG thunk_28, 38, 28     ; createMachine
UNI_THUNK_DIAG thunk_29, 46, 29     ; createMedium
UNI_THUNK_DIAG thunk_30, 60, 30     ; createNATNetwork
UNI_THUNK_DIAG thunk_31, 51, 31     ; createSharedFolder
UNI_THUNK_DIAG thunk_32, 45, 32     ; createUnattendedInstaller
UNI_THUNK_DIAG thunk_33, 58, 33     ; findDHCPServerByNetworkName
UNI_THUNK_DIAG thunk_35, 61, 35     ; findNATNetworkByName
UNI_THUNK_DIAG thunk_36, 54, 36     ; getExtraData
UNI_THUNK_DIAG thunk_37, 53, 37     ; getExtraDataKeys
UNI_THUNK_DIAG thunk_38, 48, 38     ; getGuestOSType
UNI_THUNK_DIAG thunk_39, 43, 39     ; getMachineStates
UNI_THUNK_DIAG thunk_40, 42, 40     ; getMachinesByGroups
UNI_THUNK_DIAG thunk_42, 47, 42     ; openMedium
UNI_THUNK_DIAG thunk_44, 59, 44     ; removeDHCPServer
UNI_THUNK_DIAG thunk_45, 62, 45     ; removeNATNetwork
UNI_THUNK_DIAG thunk_46, 52, 46     ; removeSharedFolder
UNI_THUNK_DIAG thunk_47, 55, 47     ; setExtraData
UNI_THUNK_DIAG thunk_48, 56, 48     ; setSettingsSecret
UNI_THUNK_DIAG thunk_49, 70, 49     ; checkFirmwarePresent

; ===== IMachine-wrapping thunks =====
; findMachine: wrap returned IMachine* in MachineProxy
; Entry: ecx=proxy, [esp]=ret, [esp+4]=BSTR, [esp+8]=&machine
thunk_34 PROC
    push    ebx
    mov     ebx, ecx
    push    ebx
    push    34
    call    diag_method_call@8
    mov     ecx, ebx
    pop     ebx
    mov     eax, dword ptr [esp+8]   ; eax = &machine
    mov     edx, dword ptr [esp+4]   ; edx = BSTR name
    push    eax                      ; param3: &machine
    push    edx                      ; param2: BSTR
    push    ecx                      ; param1: proxy
    call    wrap_findMachine_result@12
    ret     8
thunk_34 ENDP

; openMachine: wrap returned IMachine* in MachineProxy
; Entry: ecx=proxy, [esp]=ret, [esp+4]=file, [esp+8]=pwd, [esp+12]=&machine
thunk_41 PROC
    push    ebx
    mov     ebx, ecx
    push    ebx
    push    41
    call    diag_method_call@8
    mov     ecx, ebx
    pop     ebx
    mov     eax, dword ptr [esp+12]  ; eax = &machine
    mov     edx, dword ptr [esp+8]   ; edx = password
    mov     esi, dword ptr [esp+4]   ; esi = settingsFile
    push    eax                      ; param4: &machine
    push    edx                      ; param3: password
    push    esi                      ; param2: settingsFile
    push    ecx                      ; param1: proxy
    call    wrap_openMachine_result@16
    ret     12
thunk_41 ENDP

; registerMachine: no return wrapping needed
; Entry: ecx=proxy, [esp]=ret, [esp+4]=machine (MachineProxy)
thunk_43 PROC
    push    ebx
    mov     ebx, ecx
    push    ebx
    push    43
    call    diag_method_call@8
    mov     ecx, ebx
    pop     ebx
    mov     eax, dword ptr [esp+4]   ; eax = machine input
    push    eax
    push    ecx
    call    wrap_registerMachine_result@8
    ret     4
thunk_43 ENDP

; ===== IUnknown thunks =====
thunk_QI PROC
    mov     eax, dword ptr [ecx+12]   ; eax = realVBox (was +8, then +4)
    pop     edx                      ; edx = ret_eNSP
    pop     ecx                      ; ecx = riid
    push    ecx                      ; push riid
    push    eax                      ; push realVBox
    push    edx                      ; push ret_eNSP
    jmp     helper_QueryInterface@12
thunk_QI ENDP

; AddRef/Release are a COM hot path that eNSP invokes from inside an SEH
; cleanup destructor — they MUST be minimal and reentrant-safe: no diag, no
; large stack frame, no I/O. Pure tail-call, return address never leaves the
; stack (same proven shape as thunk_QI).
thunk_AR PROC
    mov     eax, dword ptr [ecx+12]   ; eax = realVBox
    pop     edx                       ; edx = ret_eNSP
    push    eax                       ; arg: realVBox
    push    edx                       ; ret_eNSP back on top
    jmp     helper_AddRef@4
thunk_AR ENDP

thunk_RL PROC
    mov     eax, dword ptr [ecx+12]   ; eax = realVBox
    pop     edx
    push    eax
    push    edx
    jmp     helper_Release@4
thunk_RL ENDP

; ===== vtable[1]: clone precondition probe (NOT AddRef) =====
; ---------------------------------------------------------------------------
; ARITY IS DISPUTED AND MUST BE SETTLED BY MEASUREMENT, NOT BY ASSUMPTION.
;
;   The genuine DLL's slot[1] disassembles to `mov eax, 2; ret 4` -- one stack
;   dword (or zero, depending on how `this` is passed). This thunk reads THREE
;   stack dwords and ends with `ret 0Ch`. Those cannot both be right: whichever
;   is wrong leaves the caller's stack permanently skewed by 8 bytes, and the
;   caller is mid-way through building a VBoxManage command line.
;
;   The three dwords this thunk reads do look like the right strings
;   ('vfw_usg' / 'vfw_usg_Link'), but the caller has just finished assembling
;   exactly those strings into a command line -- stack residue and real
;   arguments are indistinguishable by their contents. So: log the raw stack,
;   including the return address, and disassemble the caller to count the
;   pushes for real.
;
; The snapshot runs on pushad/popad so it cannot perturb the registers or the
; argument area the original body depends on.
EXTERN diag_clone_stack@4:PROC
thunk_clone_check PROC
    pushad
    mov     eax, dword ptr [esp+12]   ; ESP as it was on entry (-> caller's ret addr)
    push    eax
    call    diag_clone_stack@4
    popad

    mov     eax, dword ptr [ecx+12]   ; eax = realVBox (proxy[+12])
    mov     edx, dword ptr [esp+12]   ; pOut
    push    edx
    mov     edx, dword ptr [esp+12]   ; snap  (esp shifted +4 -> orig [esp+8])
    push    edx
    mov     edx, dword ptr [esp+12]   ; base  (esp shifted +8 -> orig [esp+4])
    push    edx
    push    eax                       ; realVBox
    call    helper_clone_check@16
    ret     0Ch                       ; clean eNSP's 3 incoming args
thunk_clone_check ENDP

; ===== Wrapper slots [5]/[6]: call the real getter, then consume TWO dwords =====
;
; NGFW_Plugin.dll pushes TWO stack dwords at these call sites, but the real VBox 7.2
; getter only pops one (its own out-param). Measured on FUN_1000dbe0:
;     call site  esp = 0x41EF838        (frame base E = 0x41EF840)
;     return     esp = 0x41EF83C        -> only 4 bytes consumed, 4 left behind
; so every pass leaked one dword and the frame ended up 4 bytes short. FUN_1000dbe0
; then read [esp+0x3C] -- normally its own argument slot, but 4 bytes lower it is the
; function's RETURN ADDRESS -- and tried to release it as a CString, faulting on
; `lock xadd [ecx], edx` with ecx = 0x1000EC16 (code, not heap).
;
; A tail jump (UNI_THUNK_DIAG) cannot fix this: the real method returns straight to
; the caller, so there is no chance to drop the surplus dword. So: `call` it, then
; correct esp before jumping back to the caller's return address.
;
; Entry layout:  [esp]=ret_to_caller (S), [esp+4]=arg1, [esp+8]=arg2
; The caller wants esp = S+12 on return, so this thunk must end in `ret 8`.
; (An earlier version ended with `add esp,12; jmp ret` -- but `jmp` does NOT pop the
;  return address, so that left esp at S+8, still 4 bytes short.)
EXTRA_POP_THUNK MACRO name, helper, diag_idx, popargs
name PROC
    push    ebx
    mov     ebx, ecx                    ; ebx = proxy
    push    ebx
    push    diag_idx
    call    diag_method_call@8          ; pops its 8; ebx still holds the proxy
    ; NOTE: ebx must NOT be restored before `push ebx` below -- an earlier revision
    ; popped ebx here (back to the caller's value) and then pushed that as `self`,
    ; so the C helper received a garbage proxy, read a garbage realVBox, and
    ; dispatched through a garbage vtable (observed as EAX=2 -> AV reading 0x2).
    mov     edx, dword ptr [esp+8]      ; S-4+8 = S+4 -> arg1 (out param)
    push    edx                         ; S-8
    push    ebx                         ; S-12: self = proxy
    call    helper                      ; C helper fills *out and returns the HRESULT
    pop     ebx                         ; S: restore the caller's ebx (does not touch eax)
    ret     popargs                     ; pass the helper's HRESULT straight through.
                                        ; NOTE: do NOT `xor eax,eax` here. An earlier
                                        ; revision forced S_OK, which silently discarded
                                        ; ngfw_chain5's E_FAIL -- the caller then took its
                                        ; "still present" branch and reported success=0 back
                                        ; to RegisterDevice as a failure. (Forcing EAX at
                                        ; 0x1000DE3E by hand worked, which is what hid it.)
                                        ; pop ret + 8 -> esp = S+12
name ENDP
ENDM

; popargs differs per slot: the two call sites were built differently.
;   slot[5] @0x1000DE3C -- caller had TWO dwords on the stack  -> ret 8
;   slot[6] @FUN_1000dfb0 -- caller pre-builds a by-value CString return (a CloneData
;                            runs immediately before the call), i.e. ONE hidden return
;                            pointer -> ret 4.  Using ret 8 there over-pops by 4 and
;                            corrupts the caller's frame; the fault then surfaces later
;                            as a wild EIP with lastMethod still showing 7.
; wrapper[4] carries the negative that FUN_1000dbe0 needs ("nothing to delete");
; wrapper[5] and [6] must stay S_OK or FUN_1000e870 aborts later.
EXTRA_POP_THUNK thunk_pop2_4, ngfw_notfound@8, 4, 4 ; wrapper[4]  popargs 4: caller pushes 1 dword
EXTRA_POP_THUNK thunk_pop2_6, ngfw_ok@8,       6, 8 ; wrapper[5]  popargs 8: caller pushes 2 dwords
EXTRA_POP_THUNK thunk_pop2_7, ngfw_ok@8,       7, 4 ; wrapper[6]  popargs 4: caller pre-builds a
                                                    ;   by-value CString return (one hidden pointer)

END
