.386
.model flat, c
.code

EXTERN machine_helper_QI@12:PROC
EXTERN machine_helper_AddRef@4:PROC
EXTERN machine_helper_Release@4:PROC

; ===== MachineProxy IUnknown thunks (slots [0]/[1]/[2]) =====
; eNSP calls these __thiscall (this in ecx). They MUST NOT route through the
; +4 IDispatch map -- doing so sent QI/AddRef/Release into GetTypeInfo/
; GetIDsOfNames/Invoke, whose ret N drifted eNSP's stack and crashed it.
; Forward the MachineProxy* (ecx) as the helper's first __stdcall arg, keeping
; eNSP's return address on the stack the whole time (never via a volatile reg
; across the call). Helpers self-clean (ret 4 / ret 12).

machine_QI PROC
    mov     eax, ecx        ; eax = this (MachineProxy*)
    pop     edx             ; edx = caller return address; [esp]=riid,[esp+4]=ppv
    push    eax             ; arg1: this
    push    edx             ; restore return address
    jmp     machine_helper_QI@12
machine_QI ENDP

machine_AR PROC
    mov     eax, ecx        ; eax = this
    pop     edx             ; caller return address (0 stack args)
    push    eax             ; arg1: this
    push    edx             ; restore return address
    jmp     machine_helper_AddRef@4
machine_AR ENDP

machine_RL PROC
    mov     eax, ecx        ; eax = this
    pop     edx             ; caller return address
    push    eax             ; arg1: this
    push    edx             ; restore return address
    jmp     machine_helper_Release@4
machine_RL ENDP

MACHINE_PROXY_REAL = 8
MACHINE_PROXY_MAP  = 12

im_e_0 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 0]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_0 ENDP

im_e_1 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 4]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_1 ENDP

im_e_2 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 8]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_2 ENDP

im_e_3 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 12]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_3 ENDP

im_e_4 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 16]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_4 ENDP

im_e_5 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 20]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_5 ENDP

im_e_6 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 24]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_6 ENDP

im_e_7 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 28]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_7 ENDP

im_e_8 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 32]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_8 ENDP

im_e_9 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 36]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_9 ENDP

im_e_10 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 40]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_10 ENDP

im_e_11 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 44]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_11 ENDP

im_e_12 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 48]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_12 ENDP

im_e_13 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 52]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_13 ENDP

im_e_14 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 56]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_14 ENDP

im_e_15 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 60]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_15 ENDP

im_e_16 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 64]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_16 ENDP

im_e_17 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 68]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_17 ENDP

im_e_18 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 72]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_18 ENDP

im_e_19 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 76]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_19 ENDP

im_e_20 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 80]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_20 ENDP

im_e_21 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 84]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_21 ENDP

im_e_22 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 88]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_22 ENDP

im_e_23 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 92]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_23 ENDP

im_e_24 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 96]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_24 ENDP

im_e_25 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 100]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_25 ENDP

im_e_26 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 104]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_26 ENDP

im_e_27 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 108]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_27 ENDP

im_e_28 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 112]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_28 ENDP

im_e_29 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 116]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_29 ENDP

im_e_30 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 120]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_30 ENDP

im_e_31 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 124]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_31 ENDP

im_e_32 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 128]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_32 ENDP

im_e_33 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 132]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_33 ENDP

im_e_34 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 136]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_34 ENDP

im_e_35 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 140]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_35 ENDP

im_e_36 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 144]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_36 ENDP

im_e_37 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 148]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_37 ENDP

im_e_38 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 152]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_38 ENDP

im_e_39 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 156]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_39 ENDP

im_e_40 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 160]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_40 ENDP

im_e_41 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 164]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_41 ENDP

im_e_42 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 168]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_42 ENDP

im_e_43 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 172]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_43 ENDP

im_e_44 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 176]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_44 ENDP

im_e_45 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 180]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_45 ENDP

im_e_46 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 184]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_46 ENDP

im_e_47 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 188]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_47 ENDP

im_e_48 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 192]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_48 ENDP

im_e_49 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 196]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_49 ENDP

im_e_50 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 200]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_50 ENDP

im_e_51 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 204]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_51 ENDP

im_e_52 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 208]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_52 ENDP

im_e_53 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 212]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_53 ENDP

im_e_54 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 216]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_54 ENDP

im_e_55 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 220]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_55 ENDP

im_e_56 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 224]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_56 ENDP

im_e_57 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 228]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_57 ENDP

im_e_58 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 232]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_58 ENDP

im_e_59 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 236]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_59 ENDP

im_e_60 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 240]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_60 ENDP

im_e_61 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 244]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_61 ENDP

im_e_62 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 248]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_62 ENDP

im_e_63 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 252]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_63 ENDP

im_e_64 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 256]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_64 ENDP

im_e_65 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 260]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_65 ENDP

im_e_66 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 264]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_66 ENDP

im_e_67 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 268]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_67 ENDP

im_e_68 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 272]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_68 ENDP

im_e_69 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 276]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_69 ENDP

im_e_70 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 280]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_70 ENDP

im_e_71 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 284]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_71 ENDP

im_e_72 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 288]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_72 ENDP

im_e_73 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 292]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_73 ENDP

im_e_74 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 296]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_74 ENDP

im_e_75 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 300]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_75 ENDP

im_e_76 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 304]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_76 ENDP

im_e_77 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 308]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_77 ENDP

im_e_78 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 312]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_78 ENDP

im_e_79 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 316]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_79 ENDP

im_e_80 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 320]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_80 ENDP

im_e_81 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 324]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_81 ENDP

im_e_82 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 328]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_82 ENDP

im_e_83 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 332]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_83 ENDP

im_e_84 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 336]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_84 ENDP

im_e_85 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 340]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_85 ENDP

im_e_86 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 344]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_86 ENDP

im_e_87 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 348]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_87 ENDP

im_e_88 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 352]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_88 ENDP

im_e_89 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 356]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_89 ENDP

im_e_90 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 360]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_90 ENDP

im_e_91 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 364]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_91 ENDP

im_e_92 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 368]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_92 ENDP

im_e_93 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 372]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_93 ENDP

im_e_94 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 376]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_94 ENDP

im_e_95 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 380]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_95 ENDP

im_e_96 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 384]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_96 ENDP

im_e_97 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 388]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_97 ENDP

im_e_98 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 392]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_98 ENDP

im_e_99 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 396]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_99 ENDP

im_e_100 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 400]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_100 ENDP

im_e_101 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 404]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_101 ENDP

im_e_102 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 408]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_102 ENDP

im_e_103 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 412]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_103 ENDP

im_e_104 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 416]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_104 ENDP

im_e_105 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 420]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_105 ENDP

im_e_106 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 424]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_106 ENDP

im_e_107 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 428]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_107 ENDP

im_e_108 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 432]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_108 ENDP

im_e_109 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 436]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_109 ENDP

im_e_110 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 440]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_110 ENDP

im_e_111 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 444]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_111 ENDP

im_e_112 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 448]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_112 ENDP

im_e_113 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 452]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_113 ENDP

im_e_114 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 456]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_114 ENDP

im_e_115 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 460]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_115 ENDP

im_e_116 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 464]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_116 ENDP

im_e_117 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 468]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_117 ENDP

im_e_118 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 472]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_118 ENDP

im_e_119 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 476]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_119 ENDP

im_e_120 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 480]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_120 ENDP

im_e_121 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 484]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_121 ENDP

im_e_122 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 488]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_122 ENDP

im_e_123 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 492]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_123 ENDP

im_e_124 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 496]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_124 ENDP

im_e_125 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 500]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_125 ENDP

im_e_126 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 504]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_126 ENDP

im_e_127 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 508]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_127 ENDP

im_e_128 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 512]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_128 ENDP

im_e_129 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 516]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_129 ENDP

im_e_130 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 520]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_130 ENDP

im_e_131 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 524]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_131 ENDP

im_e_132 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 528]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_132 ENDP

im_e_133 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 532]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_133 ENDP

im_e_134 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 536]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_134 ENDP

im_e_135 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 540]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_135 ENDP

im_e_136 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 544]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_136 ENDP

im_e_137 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 548]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_137 ENDP

im_e_138 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 552]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_138 ENDP

im_e_139 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 556]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_139 ENDP

im_e_140 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 560]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_140 ENDP

im_e_141 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 564]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_141 ENDP

im_e_142 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 568]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_142 ENDP

im_e_143 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 572]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_143 ENDP

im_e_144 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 576]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_144 ENDP

im_e_145 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 580]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_145 ENDP

im_e_146 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 584]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_146 ENDP

im_e_147 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 588]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_147 ENDP

im_e_148 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 592]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_148 ENDP

im_e_149 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 596]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_149 ENDP

im_e_150 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 600]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_150 ENDP

im_e_151 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 604]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_151 ENDP

im_e_152 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 608]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_152 ENDP

im_e_153 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 612]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_153 ENDP

im_e_154 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 616]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_154 ENDP

im_e_155 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 620]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_155 ENDP

im_e_156 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 624]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_156 ENDP

im_e_157 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 628]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_157 ENDP

im_e_158 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 632]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_158 ENDP

im_e_159 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 636]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_159 ENDP

im_e_160 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 640]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_160 ENDP

im_e_161 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 644]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_161 ENDP

im_e_162 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 648]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_162 ENDP

im_e_163 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 652]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_163 ENDP

im_e_164 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 656]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_164 ENDP

im_e_165 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 660]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_165 ENDP

im_e_166 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 664]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_166 ENDP

im_e_167 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 668]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_167 ENDP

im_e_168 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 672]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_168 ENDP

im_e_169 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 676]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_169 ENDP

im_e_170 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 680]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_170 ENDP

im_e_171 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 684]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_171 ENDP

im_e_172 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 688]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_172 ENDP

im_e_173 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 692]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_173 ENDP

im_e_174 PROC
    push    ebx
    mov     ebx, ecx
    mov     eax, dword ptr [ebx + MACHINE_PROXY_REAL]
    mov     ecx, dword ptr [ebx + MACHINE_PROXY_MAP]
    mov     ecx, dword ptr [ecx + 696]
    pop     ebx
    pop     edx
    push    eax
    push    edx
    mov     edx, ecx
    mov     ecx, eax
    mov     eax, dword ptr [eax]
    jmp     dword ptr [eax + edx*4]
im_e_174 ENDP
END
