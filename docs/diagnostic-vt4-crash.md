# 诊断报告：`eip=edx=0x00320032` 崩溃根因分析

> 接手自前一会话的动态调试成果。本报告基于静态分析 + x64dbg-automate 活体调试，已完整定位崩溃根因。
> 修正记录：spoof_diag 的 `ret 4` 清栈在初版手算中被误当 `ret`，已在 3.1 节修正。最终结论不变。

## 0. 摘要

**崩溃位置**：`eNSP_VBoxServer.exe` 加载 `NGFW_Plugin.dll` 后，在 `FUN_1000dbe0`（删除 baselink 子流程）内部调用 `IVirtualBox::vtable[4]` 时崩溃。

**根因**：垫片的 `spoof_get_versionNormalized`（vtable[4]）实现与调用方 `CVBoxWrapper` 的调用契约**根本性不匹配**：
- 调用方按 `__thiscall` 无参数调用 vtable[4]，期望返回 `proxy->vtable` 指针（身份验证用）
- 垫片实现却假设这是 `get_versionNormalized(BSTR* out)`，需要从栈上弹出一个 out 参数指针

结果：spoof 函数从栈上误弹出调用方栈帧数据（"vfw_usg" 字符串地址），`SysAllocString` 破坏 `edx` 为 `0x00320032`，最终 `push edx; ret` 跳到 `0x00320032` 崩溃。

**影响范围**：`spoof_get_version` (vtable[3])、`spoof_get_versionNormalized` (vtable[4])、`spoof_get_packageType` (vtable[6]) 三个函数都有相同 bug。`spoof_get_revision` (vtable[5]) 也有栈错位问题但不调用 SysAllocString。

---

## 1. 崩溃现象

### 1.1 表面症状

- **触发操作**：eNSP 中导入 NGFW 设备包后，点击启动 FW1
- **崩溃地址**：`eip = 0x00320032`，`edx = 0x00320032`
- **崩溃进程**：`eNSP_VBoxServer.exe`（32 位）

### 1.2 `0x00320032` 的字节级解释

`0x00320032` 看似随机，实则是 UTF-16LE 字符串 `"5.2.22"` 的尾部字节被当作函数指针解释：

```
g_ver = L"5.2.22"  的内存布局（UTF-16LE）：
偏移  +0x00 +0x01 +0x02 +0x03 +0x04 +0x05 +0x06 +0x07 +0x08 +0x09 +0x0A +0x0B +0x0C +0x0D
字节  35    00    2E    00    32    00    2E    00    32    00    32    00    00    00
字符  '5'         '.'         '2'         '.'         '2'         '2'         NUL
```

- `g_ver + 0x08` 处的 4 字节 = `32 00 32 00` = 小端 DWORD `0x00320032`
- 这正好是字符串尾部的 `"22"` 两个 UTF-16 字符
- 崩溃时 `edx = 0x00320032`，说明 `edx` 曾指向 `g_ver + 0x08` 附近，被读入后未清理

### 1.3 与已修复问题的关系

此崩溃是接手文档记载的 **layer-1 原版崩溃**，与本次会话已落地的三个修复（DllMain 误伤补丁回退、`DelVBoxInstance` 签名修正、VEH FLAG_PIN 钉死）**无关联**。回归测试已排除：三个修复未引入此崩溃。

---

## 2. 根因：调用契约冲突

### 2.1 调用方契约（CVBoxWrapper / NGFW_Plugin.dll）

从 Ghidra 反编译 `NGFW_Plugin_dll.c:12134`：

```c
iVar8 = (**(code **)(**(int **)(iVar9 + 0xc) + 0x10))();
```

解析这个表达式：
- `iVar9 = param_1`（CVBoxWrapper this 指针）
- `*(int *)(iVar9 + 0xc)` = 读取 `this+0xc` = `m_hVBox`（即垫片返回的 wrapper 指针）
- `**(int **)` = 再解引用 = wrapper->vtable（vtable 指针）
- `+ 0x10` = vtable 偏移 0x10 = `0x10 / 4 = vtable[4]`
- `()` = **无参数调用**

对应反汇编（0x1000DD4C–0x1000DD57）：

```asm
0x1000DD4C  mov ecx, [ebp+0x0C]   ; ecx = this (CVBoxWrapper)
0x1000DD4F  mov edx, [ecx]        ; edx = this->m_hVBox (wrapper ptr)
0x1000DD51  mov eax, [edx+0x10]   ; eax = wrapper->vtable[4]  (偏移0x10=槽4)
0x1000DD54  add esp, 0x04         ; 调整栈（前一次调用的cdecl清理残留）
0x1000DD57  call eax              ; __thiscall, 无参数, ecx=wrapper(this)
```

**关键**：这是 `__thiscall`，`ecx = wrapper`，**栈上不压任何参数**。调用方期望 `eax` 返回值用于身份验证（与 `proxy->vtable` 比较）。

### 2.2 CVBoxWrapper 的身份验证契约

`FUN_1000dbe0` 调用 vtable[4] 不是为了取版本字符串，而是做**身份验证**：
- CVBoxWrapper 在 `LoadVBox` 阶段保存了首次拿到的 wrapper 指针
- 后续每次调用前，会重新调用 vtable[4] 并检查返回值是否等于保存的 wrapper 指针
- 这是一种"这个 IVirtualBox 还是不是我当初那个"的活性探针

所以 vtable[4] 必须返回 **wrapper 指针**（或 `proxy->vtable`），**绝不能**是 `S_OK` 或 BSTR。

### 2.3 垫片实现契约（错误假设）

`spoof_thunks.cpp:51-69`：

```c
extern "C" __declspec(naked) void spoof_get_versionNormalized() {
    __asm {
        push ecx                      ; [1] 保存 this
        push 1                        ; [2] diag 参数
        call spoof_diag               ; [3] 诊断
        pop  ecx                      ; [4] 清理 diag 参数
        call spoof_save_proxy         ; [5] 保存 this 到 g_spoof_proxy
        pop  edx                      ; [6] ★弹出 ret 地址
        pop  ecx                      ; [7] ★弹出"out 参数"（实际是调用方栈帧！）
        push ecx                      ; [8] 压回 out 参数
        push offset g_ver             ; [9] 压入 "5.2.22"
        call SysAllocString           ; [10] 分配 BSTR
        pop  ecx                      ; [11] 清理 g_ver 参数
        mov  [ecx], eax               ; [12] ★写 BSTR 到"out 参数"（破坏调用方栈！）
        call spoof_get_vtable         ; [13] eax = proxy->vtable
        push edx                      ; [14] ★压入被破坏的 edx
        ret                           ; [15] ★弹 edx 到 eip → 崩溃
    }
}
```

垫片假设这是 `get_versionNormalized(BSTR* out)` 的 `__thiscall`：
- `ecx = this`
- 栈上有一个 `BSTR*` out 参数
- 调用方会用 `ret 4` 清理

**但实际调用是无参数 `__thiscall`**，栈上根本没有 out 参数！步骤 [6] 和 [7] 弹出的不是 ret 地址和 out 参数，而是**调用方的栈帧数据**。

---

## 3. 静态分析证据

### 3.1 栈平衡手算（修正版）

> **修正记录**：初版手算把 `spoof_diag` 的 `ret 4` 当成普通 `ret`，导致中间过程描述错误。修正后与动态实测完全吻合。
>
> `spoof_diag` 声明为 `__stdcall(int idx)`（`vbox52_proxy.cpp:171`），callee 清栈，返回时是 `ret 4`（弹 ret 地址 + 清 4 字节参数）。

入口栈状态（无参数 `__thiscall` 调用，esp=0 为基准）：

```
[esp+0]  = ret_addr (0x1000DD59)
[esp+4]  = 调用方栈帧数据 ("vfw_usg" 指针 0x041AEF90)
```

逐步追踪栈指针变化：

| 步骤 | 指令 | esp 偏移 | 栈顶含义 |
|------|------|---------|---------|
| 入口 | - | 0 | ret_addr=0x1000DD59 |
| [1] push ecx | esp-4 | -4 | this (0x03B420E4) 保存 |
| [2] push 1 | esp-4 | -8 | diag 参数 |
| [3] call spoof_diag | esp-4 | -12 | diag 的 ret |
| [3] **spoof_diag `ret 4`** | **esp+8** | **-4** | **this**（弹 diag_ret + 清参数 1）★ 修正点 |
| [4] pop ecx | esp+4 | 0 | ecx ← this（恢复），栈顶回到 ret_addr |
| [5] call spoof_save_proxy | esp-4 | -4 | save_proxy 的 ret |
| [5] save_proxy `ret` | esp+4 | 0 | 栈顶 = ret_addr |
| **[6] pop edx** | **esp+4** | **+4** | **edx ← ret_addr (0x1000DD59)** ★ 修正：不是 this |
| **[7] pop ecx** | **esp+4** | **+8** | **ecx ← "vfw_usg" 指针 (0x041AEF90)** ★ 修正：不是 ret_addr |
| [8] push ecx | esp-4 | +4 | 压回 "vfw_usg" 指针 |
| [9] push offset g_ver | esp-4 | 0 | g_ver 地址 |
| [10] call SysAllocString | esp-4 | -4 | SysAlloc 的 ret |
| [10] SysAllocString `ret 4` (stdcall) | esp+8 | +4 | 清掉 g_ver 和压回的 "vfw_usg" 指针 |
| [11] pop ecx | esp+4 | **+8** | **ecx ← "vfw_usg" 指针 (0x041AEF90)** ★ 与动态实测一致 |
| [12] mov [ecx],eax | - | +8 | ★把 BSTR 写到 "vfw_usg" 地址（破坏！）|
| [13] call spoof_get_vtable | esp-4 | +4 | get_vtable 的 ret |
| [13] get_vtable `ret` | esp+4 | +8 | 栈顶 = 调用方栈帧 |
| [14] push edx | esp-4 | +4 | 压入 edx（此时已被污染为 0x00320032）|
| [15] ret | esp+4 | +8 | **eip ← edx = 0x00320032** ★ 崩溃 |

**关键观察**：
- 步骤 [6] 弹给 `edx` 的是 **ret_addr (0x1000DD59)**，不是 this。这一点修正了初版手算的错误。
- 步骤 [10] `SysAllocString` 的 `ret 4` 把栈对齐回了 +4 偏移，使步骤 [11] `pop ecx` 拿到 "vfw_usg" 指针，与动态实测一致。
- 步骤 [14] `push edx` 压入的是 **被 SysAllocString 污染后的 0x00320032**（不是初版推论的"未被破坏的 this"）。这反而更直接解释了 `eip = 0x00320032`。

### 3.2 为什么 edx 变成 `0x00320032`

`__stdcall` 调用约定**不保留 edx**。`SysAllocString` 内部会用 edx 做临时寄存器。当 `SysAllocString` 处理 `L"5.2.22"` 这个 BSTR 时，内部某处把 `g_ver + 0x08` 的字节（`32 00 32 00` = `0x00320032`）读入 edx，返回后 edx 未被恢复。

步骤 [14] `push edx` 压入的就是这个被污染的 `0x00320032`，步骤 [15] `ret` 把它弹给 `eip`。

### 3.3 关键矛盾

垫片代码里有一个根本性的认知错误：作者以为 vtable[4] 是 `get_versionNormalized(BSTR* out)`，需要伪装版本字符串返回给调用方。

但 NGFW 的 CVBoxWrapper **根本不调用 vtable[4] 来取版本**——它调用 vtable[4] 是做身份验证。版本伪装应该只在 vtable[3] (get_version) 被显式调用时才需要，而 vtable[4] 应该是个纯 passthrough 或返回 wrapper 指针。

---

## 4. 动态调试证据链

以下证据来自上一会话用 x64dbg-automate MCP 附加到 `eNSP_VBoxServer.exe`（PID 29712）的活体调试。

### 4.1 断点命中位置

在 `0x1000DD4C`（bp_before_vt4，vtable[4] 调用前一条）设断点，命中后读取现场：

```
eip  = 0x1000DD4C
ecx  = 0x03B420E4   ; wrapper ptr (this)
[ecx]   = 0x6C7A3008  ; vtable ptr
[ecx+0x10] = 0x6C7847D0  ; vtable[4] = spoof_get_versionNormalized
```

### 4.2 wrapper 内存完整 dump

读取 0x03B420E4 处 16 字节：

```
08 30 7A 6C   E4 20 B4 03   E4 20 B4 03   EC 7C 6F 00
^^^^^^^^^     ^^^^^^^^^^^   ^^^^^^^^^^^   ^^^^^^^^^^^
vtable ptr    self1         self2         realVBox
0x6C7A3008    0x03B420E4    0x03B420E4    0x006F7CEC
```

wrapper 内存**完全未被破坏**，vtable 指针正确指向 `g_vbox52_vtable`（0x6C7A3008）。这排除了"wrapper 被写坏"的假说。

### 4.3 vtable[4] 验证

读取 0x6C7A3008 处 vtable：

```
vtable[0] = thunk_QI
vtable[1] = thunk_clone_check
vtable[2] = thunk_RL
vtable[3] = spoof_get_version       (0x6C784760)
vtable[4] = spoof_get_versionNormalized  (0x6C7847D0)  ← 崩溃入口
vtable[5] = spoof_get_revision      (0x6C784840)
vtable[6] = spoof_get_packageType   (0x6C7848B0)
```

vtable 布局**完全正确**，vtable[4] 确实指向 `spoof_get_versionNormalized`。

### 4.4 调用前栈顶内容

进入 spoof 函数前 `[esp] = 0x041AEF90`。读取该地址 16 字节：

```
76 00 66 00 77 00 5F 00 75 00 73 00 67 00 00 00
v     f     w     _     u     s     g     NUL
```

即 UTF-16LE 字符串 `L"vfw_usg"`。这是 CVBoxWrapper 的局部变量（CString 的数据缓冲区），**不是** BSTR out 参数。

**铁证**：调用方栈顶是 "vfw_usg" 字符串指针，证明 vtable[4] 是无参数调用，栈上没有 out 参数。

### 4.5 step into spoof_get_versionNormalized 后逐步寄存器

| 步骤 | eip | ecx | edx | 说明 |
|------|-----|-----|-----|------|
| 入口 | 0x6C7847D0 | 0x03B420E4 | 0x6C7A3008 | this=wrapper, edx=vtable |
| step over 8 条到 0x6C7847E1 | - | 0x03B420E4 | - | 到 `push offset g_ver` 之前 |
| step over 3 条到 0x6C7847ED | - | **0x041AEF90** | **0x00320032** | `mov [ecx],eax` 执行点，edx 已被 SysAllocString 破坏 |
| step over 4 条完成 | **0x00320032** | - | 0x00320032 | `push edx; ret` 已执行，eip=edx=0x00320032 |

**与修正后手算的对应关系**：
- 动态实测 `ecx=0x041AEF90`（"vfw_usg" 指针）出现在 `mov [ecx],eax` 执行点 → 对应手算步骤 [12]，此时 ecx 来自步骤 [11] `pop ecx`。
- 手算修正后步骤 [11] `pop ecx` 拿到的正是 "vfw_usg" 指针 → **完全吻合**。
- 初版手算因 spoof_diag 的 `ret 4` 笔误，步骤 [11] 拿到的值对不上；修正后与动态实测一致。

### 4.6 与用户报告的一致性

用户原始报告：`eip=edx=0x00320032`。动态调试最终状态：`eip=0x00320032, edx=0x00320032`。**完全一致**。

---

## 5. 完整崩溃机制（指令级时间线）

```
T0  eNSP_VBoxServer.exe 启动 → 加载 NGFW_Plugin.dll → 调用 Init()
T1  Init() 调用 FUN_1000dbe0（删除旧 baselink 子流程）
T2  FUN_1000dbe0 在 0x1000DD4C 准备调用 vtable[4]
        mov ecx, [ebp+0x0C]   ; ecx = 0x03B420E4 (wrapper)
        mov edx, [ecx]        ; edx = 0x6C7A3008 (vtable)
        mov eax, [edx+0x10]   ; eax = 0x6C7847D0 (vtable[4])
        add esp, 0x04
        call eax              ; 进入 spoof_get_versionNormalized
                             ; [esp] = 0x1000DD59 (ret addr)
                             ; [esp+4] = 0x041AEF90 ("vfw_usg" 串)

T3  进入 spoof_get_versionNormalized (0x6C7847D0)
    垫片误以为是 get_versionNormalized(BSTR* out)：
        push ecx              ; 保存 this
        push 1; call spoof_diag; pop ecx   ; 诊断（spoof_diag 用 ret 4 清栈）
        call spoof_save_proxy ; 保存 this
        pop edx               ; ★ edx ← ret_addr (0x1000DD59)，本应弹 ret
        pop ecx               ; ★ ecx ← "vfw_usg" 指针 (0x041AEF90)，本应弹 out
        push ecx              ; 压回 "vfw_usg" 指针
        push offset g_ver     ; 压入 "5.2.22"
        call SysAllocString   ; stdcall, eax = BSTR 堆地址
                             ; ★ edx 被 SysAllocString 破坏为 0x00320032
        pop ecx               ; ecx ← 0x041AEF90 ("vfw_usg" 串，被 ret 4 推回到这里)
        mov [ecx], eax        ; ★ 把 BSTR 写到 "vfw_usg" 串地址！破坏！
        call spoof_get_vtable ; eax = proxy->vtable (0x6C7A3008)
        push edx              ; ★ 压入 0x00320032（被污染的 edx）
        ret                   ; ★ eip ← 0x00320032 → 崩溃！

T4  eip = 0x00320032 → 该地址无映射/不可执行 → 访问违例 → 进程崩溃
```

---

## 6. 副作用分析

### 6.1 "vfw_usg" 字符串被破坏

步骤 `mov [ecx], eax` 把 BSTR 堆地址写到 `0x041AEF90`（"vfw_usg" 字符串数据区），覆盖了前 4 字节：

```
原: 76 00 66 00 77 00 5F 00 75 00 73 00 67 00 00 00  ("vfw_usg")
后: XX XX XX XX 77 00 5F 00 75 00 73 00 67 00 00 00  (前4字节变BSTR指针)
```

由于崩溃立即发生，这个副作用没有可观察后果。但如果修复了 `push edx; ret` 的崩溃，这个副作用会变成"vfw_usg 字符串被破坏成乱码"，导致后续 `FUN_1000dae0`（ShellExecuteExW 执行 VBoxManage snapshot delete）拿到错误的 VM 名。

### 6.2 ret 地址被弹出但未用于返回

步骤 `pop edx`（[6]）弹出了 ret 地址 0x1000DD59 给 edx，但 edx 随后被 SysAllocString 污染，ret 地址丢失。函数无法正常返回到调用方，最终跳到 0x00320032。

---

## 7. 影响范围

### 7.1 同样有 bug 的函数

三个 BSTR getter 都用相同的 `pop edx; pop ecx; ...; push edx; ret` 模式：

| vtable 槽 | 函数 | 调用 SysAllocString | 栈错位 | 崩溃风险 |
|-----------|------|---------------------|--------|---------|
| [3] | spoof_get_version | 是 | 是 | 高（若被无参调用）|
| [4] | spoof_get_versionNormalized | 是 | 是 | **当前崩溃** |
| [6] | spoof_get_packageType | 是 | 是 | 高（若被无参调用）|
| [5] | spoof_get_revision | 否 | 是 | 中（edx 不被污染，但栈仍错位）|

### 7.2 实际触发条件

只有 vtable[4] 被 CVBoxWrapper 用作身份验证探针时才会触发崩溃。vtable[3]/[5]/[6] 如果被正常 `__thiscall` 带 out 参数调用（真正的 get_version(BSTR*) 等），反而不会崩溃——因为那时栈上真的有 out 参数，`pop ecx` 弹出的就是合法 out 指针。

但 NGFW 的 CVBoxWrapper 是否也用 vtable[3]/[5]/[6] 做身份验证？目前未确认。保守起见，四个函数都应修复为契约正确的实现。

### 7.3 契约正确的实现应该是什么

vtable[4] 被 CVBoxWrapper 用作身份验证时：
- **正确行为**：返回 `proxy->vtable` 指针（与 `eax = wrapper->vtable` 等价），无副作用
- **不应**：分配 BSTR、写 out 参数、破坏调用方栈

vtable[3]/[5]/[6] 被真正调用取版本/修订号/包类型时：
- **正确行为**：`__thiscall`，栈上有一个 `BSTR*` out 参数，分配 BSTR 写入，返回 `S_OK`
- 当前的 spoof 实现对这个场景是**正确**的（除了 `push edx; ret` 的尾巴）

**矛盾**：同一个 vtable 槽可能被两种契约调用。修复必须区分这两种情况，或者让 spoof 函数同时满足两种契约。

实际上，CVBoxWrapper 的身份验证只在 vtable[4] 上做（从反编译看，只有 `+0x10` 这一处）。vtable[3]/[5]/[6] 没有身份验证调用。所以：
- vtable[4] 应改成纯身份验证（返回 vtable 指针，不分配 BSTR）
- vtable[3]/[5]/[6] 保持版本伪装逻辑，但修复 `push edx; ret` 的栈错位

---

## 8. 修复方案选项

### 方案 A：仅修 vtable[4]（最小修复，推荐）

把 `spoof_get_versionNormalized` 改成纯身份验证：

```c
extern "C" __declspec(naked) void spoof_get_versionNormalized() {
    __asm {
        ; __thiscall, 无参数, 返回 proxy->vtable
        mov  eax, ecx          ; eax = this (wrapper)
        mov  eax, [eax]        ; eax = wrapper->vtable
        ret                     ; 干净返回, 无栈操作
    }
}
```

- **优点**：改动最小，直接解决当前崩溃
- **风险**：如果别处真的调用 vtable[4] 取版本字符串，会拿到 vtable 指针而非 BSTR。但从反编译看，NGFW 不这样用
- **不破坏版本伪装**：vtable[3] (get_version) 仍然返回 "5.2.22"

### 方案 B：修所有 4 个 spoof 函数

把 vtable[3]/[4]/[5]/[6] 都改成纯身份验证（返回 vtable 指针）：

- **优点**：彻底消除所有栈错位风险
- **风险**：丧失版本伪装能力。如果 eNSP 别处真的调用 get_version/get_revision 取版本，会拿到错误值
- **不推荐**：过度修复，可能引入新问题

### 方案 C：修 3 个 BSTR getter 的栈错位（保留版本伪装）

只修 `spoof_get_version`/`spoof_get_versionNormalized`/`spoof_get_packageType` 的 `push edx; ret` 尾巴，改成正确的 `__thiscall` 返回：

```c
; 修复后的通用模式（BSTR getter）
    pop  edx               ; 弹 ret 地址
    pop  ecx               ; 弹 out 参数
    push edx               ; 压回 ret 地址（保持栈平衡）
    push offset g_ver
    call SysAllocString    ; stdcall, 清理 1 参
    mov  [ecx], eax        ; 写 BSTR 到 out
    mov  eax, 0            ; S_OK
    ret                    ; __thiscall 无 ret N, 调用方清栈
```

但这对 vtable[4] 的身份验证调用**仍然崩溃**——因为无参数调用时 `pop ecx` 弹出的是调用方栈帧数据。

- **优点**：vtable[3]/[6] 的真实版本取值场景被修复
- **风险**：vtable[4] 身份验证场景仍崩溃，需要额外处理

### 方案 D（最稳妥）：vtable[4] 改身份验证 + vtable[3]/[5]/[6] 修栈错位

- vtable[4]：改成方案 A 的纯身份验证
- vtable[3]/[5]/[6]：改成方案 C 的正确 `__thiscall` BSTR/ULONG getter
- **优点**：两种契约都满足
- **缺点**：改动面最大，但都是必要的

---

## 9. 调试环境干扰说明（供复现参考）

本次动态调试有两个已知干扰源，复现时需注意：

1. **多线程 TLS 回调干扰**：`go()` 后可能命中其他线程的 TLS 回调断点（如 `servingcommon.dll`），而非目标断点。解决：用 `g` 命令直接继续，或在 x64dbg 设置 `SetBreakOnTlsCallbacks, 0`
2. **事件时序滞后**：`go()` + `wait_for_event` 拿到的"命中"有时对应已越过断点之后的状态。解决：每次 `wait_for_event` 后都执行 `get_all_registers` 验证 `eip` 真实位置，不直接信任事件时序

---

## 10. 关键地址与值速查表

| 符号 | 值 | 说明 |
|------|-----|------|
| 崩溃 eip | 0x00320032 | "5.2.22" 尾部 "22" 的 UTF-16LE |
| wrapper ptr | 0x03B420E4 | CVBoxWrapper 的 m_hVBox |
| vtable ptr | 0x6C7A3008 | g_vbox52_vtable 地址 |
| vtable[4] | 0x6C7847D0 | spoof_get_versionNormalized 入口 |
| 调用点 | 0x1000DD57 | `call eax`（vtable[4] 调用）|
| ret 地址 | 0x1000DD59 | 调用方下一条指令 |
| "vfw_usg" 串 | 0x041AEF90 | 调用方栈帧上的 CString 数据 |
| g_ver | (静态) | L"5.2.22" 字符串 |

---

## 11. 结论

崩溃根因是**垫片对 vtable[4] 调用契约的误解**。CVBoxWrapper 用 vtable[4] 做无参数身份验证（期望返回 vtable 指针），而垫片假设它是 `get_versionNormalized(BSTR* out)` 并执行了错误的栈操作。`SysAllocString` 破坏 `edx` 为 `0x00320032`，最终 `push edx; ret` 跳到该地址崩溃。

**推荐修复**：方案 A（仅修 vtable[4] 为纯身份验证），最小改动直接解决崩溃。若担心 vtable[3]/[5]/[6] 也有潜在栈错位风险，可选方案 D。

---

## 附录 A：修正记录

初版报告（2026-07-06 早些时候）的 3.1 节手算表格存在笔误：

| 项目 | 初版（错误） | 修正版 |
|------|------------|--------|
| spoof_diag 返回 | `ret` | `ret 4`（__stdcall 清 1 参）|
| 步骤 [6] pop edx 拿到 | this (0x03B420E4) | ret_addr (0x1000DD59) |
| 步骤 [7] pop ecx 拿到 | ret_addr (0x1000DD59) | "vfw_usg" 指针 (0x041AEF90) |
| 步骤 [14] push edx 压入 | "未被破坏的 this" | 被污染的 0x00320032 |

修正后与动态实测（4.5 节）完全吻合。最终结论（崩溃根因、影响范围、修复方案）不受影响。

笔误的来源：初版手算时把 `spoof_diag` 的 `__stdcall(int)` 清栈当成普通 `ret`，少算了 +4 的清栈偏移。这导致中间过程的栈顶含义错位，但被步骤 [10] `SysAllocString` 的 `ret 4` "自愈"——后续栈语义反而对上了。这是巧合，不是设计。
