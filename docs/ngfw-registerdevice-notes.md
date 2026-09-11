# NGFW 插件 `RegisterDevice` 链路逆向笔记

记录"eNSP 自带导入框 → 弹框 → 启动"这条路径上,防火墙插件自行建库时崩溃的完整排查过程。
面向后续接手者,内容以实测数据与反编译结论为准。

## 一、问题定位

**症状**:全新状态下(镜像已由 eNSP 导入框拷入 `plugin\ngfw\Database\`、`vfw_usg` 未注册),
在 eNSP 里启动 USG6000V,`eNSP_VBoxServer.exe` 立即崩溃,界面上无任何提示。

**与既有认知的区别**:此前记录的"缺镜像时服务进程退出"是另一条路径。本次是**镜像在位、只是
VM 未注册**——即"用 eNSP 自带导入框完成导入"之后必然处于的状态。

## 二、为什么以前从未崩过

`NGFW_Plugin.dll` 的 `Init()`(导出序号 7)无条件调用 `FUN_1000eb40()`(`RegisterDevice`),
该函数第一个分支就是短路:

```c
if (设备已存在) { log "Device has already existed."; return 0; }
否则 { 删 baselink → 删 base → 建 base → 补 baselink }
```

`import_device.ps1` 会预先注册 VM 并补快照,所以插件每次加载都走短路分支,
**后面四个函数从未被执行过**。用 eNSP 自带导入框只放镜像、不注册 VM,才第一次真正触发这条链。

日志中出现 62 次 `Device has already existed.` 可印证短路的频率。

## 三、正品 VBox52.dll 的 `GetVBoxInstance` 架构

对 `originals\VBox52_original.dll` 反编译得到(地址为 ImageBase 0x10000000 下的 VA):

```c
CoCreateInstance(CLSID = B1A7A4F2-47B9-4A1E-82B2-07CCD5323C3F,   // VirtualBox 本体
                 IID   = 2CE10519-3C09-45D8-A12D-E887786146B7,   // IVirtualBox 5.2
                 &local_30c);
puVar5 = HeapAlloc(GetProcessHeap(), 8, 8);      // 只分配 8 字节
*puVar5    = &PTR_FUN_10020000;                  // [+0] = vtable
puVar5[1]  = local_30c;                          // [+4] = 内层真 IVirtualBox
return puVar5;
```

**对象只有 8 字节,`[+4]` 是内层真对象。**

正品 vtable 的前 10 槽(从 DLL 字节读出):

| 槽 | VA | 行为 |
|---|---|---|
| [0] | 0x10001000 | — |
| [1] | 0x10001250 | clone 前置探测(3 参数,ret 0xc) |
| [2] | 0x10001260 | — |
| [3] | 0x10001CF0 | 转发 `inner[7]`,返回原始 HRESULT |
| [4] | 0x10002080 | `inner[7]`,取 BSTR,取不到返回 E_FAIL |
| [5] | 0x10002420 | `inner[9]` → 失败退 `inner[8]` → 再退 `inner[10]` |
| [6] | 0x100027E0 | `inner[10]` → 失败退 `inner[7]` → 再退 `inner[9]`,取 BSTR |
| [7] | 0x10001270 | — |
| [8] | 0x10001430 | — |
| [9] | 0x100015F0 | — |

转发经两个 helper:

```c
BSTR FUN_10003f70(int *obj, int n) {          // 取 BSTR
    iVar1 = (**(code **)(*obj + n * 4))(obj, &out);   // 调 obj->vtable[n]
    if (iVar1 < 0) { if (out) SysFreeString(out); return NULL; }
    return out ? out : NULL;
}
undefined4 FUN_10004010(int *obj, int n) {    // 取 32 位值
    iVar1 = (**(code **)(*obj + n * 4))(obj, &out);
    return (iVar1 >= 0) ? out : 0;
}
```

**四个槽全部带一个出参**(`this` 在 ecx,出参在栈上,callee 用 `ret 4` 清栈)。

索引 7/8/9/10 是 **5.2 IVirtualBox 的槽号**(7=APIVersion、8=APIRevision、9=homeFolder、
10=settingsFilePath)。

## 四、垫片的偏差

`src/spoof_thunks.cpp` 把槽 [3]-[6] 实现为:

```asm
xor  eax, eax       ; S_OK
ret                 ; 零参出栈
```

**不读参数、不写出参,且清栈约定与调用方不符。** 该文件头部注释记录了 2026-07-13 的一次
调整,当时把 `ret 4` 改成 `ret` 以消除"栈失衡",结论是"插件只把这几个槽当版本探测,返回
S_OK 即可"——该结论对槽 [3]-[6] 的实际调用约定判断有误。

## 五、`FUN_1000dbe0` 的栈帧与实测数据

该函数**无帧指针**(ebp 装的是 CVBoxWrapper),局部变量全部 esp 相对寻址,
因此任何 esp 偏移都会导致读到错误的槽。

序言(逐条核对):

```asm
0x1000DBE0  push 0xFFFFFFFF / push 0x10040070 / push fs:[0]   ; SEH 3 dword
0x1000DBEE  sub  esp, 0x18                                    ; 局部变量区
0x1000DBF1  push ebx / ebp / esi / edi                        ; 4 寄存器
0x1000DBFC  push eax                                          ; 栈 cookie
0x1000DC07  mov  ebp, [esp+0x3C]                              ; 参数 = CVBoxWrapper
```

设入口 `esp = entry`,`push` 链后**帧基址 `E = entry - 0x38`**。布局:

| 偏移 | 内容 |
|---|---|
| `E+0x00` | 栈 cookie |
| `E+0x04..0x10` | edi / esi / ebp / ebx |
| `E+0x14..0x2B` | `sub esp,0x18` 的局部变量 |
| `E+0x2C..0x37` | SEH 记录 |
| `E+0x38` | 返回地址 |
| `E+0x3C` | 参数 |

实测(调试器断点前后各读一次 esp):

| 调用点 | 调用前 esp | 调用后 esp | 差值 |
|---|---|---|---|
| 槽[4] @ `0x1000DD57` | `0x41EF83C` (= E-4) | `0x41EF840` (= E) | **4** ✓ |
| 槽[5] @ `0x1000DE3C` | `0x41EF838` (= E-8) | `0x41EF83C` (= E-4) | **4** ✗ 应为 8 |

槽[5] 调用点压了 2 个 dword,被调方只弹 4,导致**每次经过帧少 4 字节**。帧偏移后
`[esp+0x3C]` 从"参数槽"变成"返回地址",代码于是把 `0x1000EC1A` 当作 CString 去析构。

## 六、两次修改与结果

**第一版**:槽 [3]/[4] 改用 `thunk_4`(尾跳到 realVBox[11]),槽 [5]/[6] 用 `thunk_6`/`thunk_7`。

结果:崩溃点从 `0x10002815` 后移到 `0x1000DE94`,且实测 `ESP = E` —— **帧对齐修复确认有效**。

**第二版**:新增 `EXTRA_POP_THUNK` 宏(见 `src/vbox52_thunks.asm`),槽 [5]/[6] 改为
`call` 真方法后手工修正 esp,而非尾跳:

```asm
    mov  edx, [esp+4]       ; arg1
    push edx
    push eax                ; this
    mov  edx, [eax]
    mov  edx, [edx+vtable_idx*4]
    call edx                ; 真方法 ret 8,弹 this+arg1
    mov  edx, [esp+4]       ; 返回地址
    add  esp, 12            ; 丢掉自己的 arg1 副本 + 调用方两个 dword
    jmp  edx
```

结果:帧对齐保持正确(`ESP = E`),但**新的失败出现**,性质改变。

## 七、当前残留问题

崩溃性质从"栈错位读到返回地址"变成**"字符串被当作对象指针"**:

```
EIP = 0x425029A = EDX + 2          ESI = 0x4250288 = EDX - 0x10
ESP = 0x41EF840 = E                ← 帧正确
异常码 0xC0000096 (STATUS_PRIVILEGED_INSTRUCTION)
```

`EIP` 处的字节按 UTF-16LE 解码为 BSTR 内容:

```
81 04 | 77 00 5F 00 75 00 73 00 67 00 | 00 00
len   | w     _     u     s     g      | L'\0'      → "w_usg"( "vfw_usg" 的片段)
```

即:代码拿一个 CString 的 `pStringMgr` 去取 vtable,而该字段指向了字符串自身:

```asm
mov ecx, [esi]        ; ecx = pStringMgr
mov eax, [ecx]        ; eax = "vtable"  ← 读到的是字符串内容
mov edx, [eax+4]
call edx              ; 跳进字符串
```

**已排除**:`0x1000DE4B` / `0x1000DE69` / `0x1000DE87` / `0x1000DEC6` / `0x1000DEE7` /
`0x1000DF05` 六处析构链断点全部未命中,说明执行流走的是 `0x1000DE45` 的 `jl 0x1000DED0` 分支。

## 八、下一步

1. **补全真品的回退链**。槽 [5] 应为 `inner[9] → inner[8] → inner[10]`,槽 [6] 应为
   `inner[10] → inner[7] → inner[9]`;当前只试了首项。真品在取不到时会依次回退,
   这个差异可能就是"取到了错误的指针"的来源。
   对应 7.2 槽号:9→13、8→12、10→14。
2. 在 `0x1000DED0` 与 `0x1000DE62` 布断点,确认实际执行到哪一条。
3. 用全指令追踪抓崩溃前数十条指令。注意 `trace_over` 的 `log_file` 参数在本环境会失败,
   需另找落盘方式。

## 九、复现步骤

```
1. eNSP 全新状态,Database\ 内放好 vfw_usg.vdi(缺镜像时 eNSP 会弹导入框)
2. 确认 vfw_usg 未注册:VBoxManage list vms
3. 启动 eNSP → 拉一台 USG6000V → 点「启动」
4. 崩溃证据:%ProgramData%\ensp-vbox-shim\vbox52_crash.log
   插件日志:plugin\ngfw\LogFile\infolog0.txt(崩溃前不增长)
```

**注意**:插件 `Init` 只在加载时执行一次。崩溃或初始化失败后,eNSP 会卸载插件,
后续点击「启动」不会再触发,表现变为 error 40。**每次复现都需重启 eNSP。**

## 十、调试要点

- `GetVBoxInstance` 在 `vbox52.dll` 中的 RVA 为 `0x3800`;插件 `NGFW_Plugin.dll` 无 ASLR,
  固定加载于 `0x10000000`。
- x64dbg 的 `set_breakpoint`(MCP 封装)对绝对地址会失败,须用原生命令 `bp 0xADDR`。
- 进程未加载该模块时无法预挂断点(`ngfw_plugin.dll+0xdbe0` 会被解析成 `0xdbe0`)。
  可靠做法:先断在 `vbox52.dll+0x3800`(此时插件已加载),再挂插件断点。
- x64dbg 会反复自动暂停在 `<模块>+0x91E0`(系统调用处),不是断点,需手动 F9 放行。
- `clear_breakpoint` 不带地址会清除**全部**软件断点。
