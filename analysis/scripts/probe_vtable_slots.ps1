# probe_vtable_slots.ps1 — 在活的 VirtualBox 7.2 IVirtualBox 对象上直接点槽位
#
# 目的：判定 7.2.8 IVirtualBox 的方法区到底从 36 还是 48 起。
#   typelib 解析（analysis/output/vbox728_vtable.md） 说 48 起 → [53]=FindMachine, [41]=保留属性
#   CLAUDE.md 表                                     说 36 起 → [41]=FindMachine, [53]=getExtraDataKeys
#
# 做法：绕过注册表（本机 CLSID 被垫片劫持），直接 LoadLibrary Oracle 原版 VBoxC.dll，
#       走 DllGetClassObject → IClassFactory::CreateInstance 拿真 7.2 IVirtualBox，
#       然后再点 vtable[41] / vtable[53]。
#
# 判据：传一个存在的 VM 名。真 FindMachine 返回 S_OK 且出参非空；
#       保留属性是 InternalAndReservedAttributeN，实现返回 E_NOTIMPL (0x80004001)。

$ErrorActionPreference = "Stop"

$cs = @'
using System;
using System.Runtime.InteropServices;

public static class VBoxProbe {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibraryW(string lpFileName);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string lpProcName);
    [DllImport("ole32.dll")]
    public static extern int CoInitializeEx(IntPtr pvReserved, uint dwCoInit);
    [DllImport("ole32.dll")]
    public static extern void CoUninitialize();

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int DllGetClassObjectFn(ref Guid rclsid, ref Guid riid, out IntPtr ppv);

    // 调用任意 vtable 槽：(this, BSTR, void* out) —— 覆盖 getter 与单参方法两种形状
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int SlotFn(IntPtr self, IntPtr arg, IntPtr outPtr);

    public static Guid CLSID_VirtualBox = new Guid("B1A7A4F2-47B9-4A1E-82B2-07CCD5323C3F");
    public static Guid IID_IClassFactory  = new Guid("00000001-0000-0000-C000-000000000046");
    public static Guid IID_IVirtualBox    = new Guid("2CE10519-3C09-45D8-A12D-E887786146B7");

    public static IntPtr CreateRealVBox(string vboxcPath) {
        IntPtr h = LoadLibraryW(vboxcPath);
        if (h == IntPtr.Zero) throw new Exception("LoadLibrary 失败: " + Marshal.GetLastWin32Error());
        IntPtr pfn = GetProcAddress(h, "DllGetClassObject");
        if (pfn == IntPtr.Zero) throw new Exception("找不到 DllGetClassObject");
        var dgco = (DllGetClassObjectFn)Marshal.GetDelegateForFunctionPointer(pfn, typeof(DllGetClassObjectFn));

        Guid clsid = CLSID_VirtualBox, iidCf = IID_IClassFactory;
        IntPtr pcf;
        int hr = dgco(ref clsid, ref iidCf, out pcf);
        if (hr != 0) throw new Exception("DllGetClassObject hr=0x" + hr.ToString("X8"));

        // IClassFactory::CreateInstance 在 vtable[3]
        IntPtr cfvt = Marshal.ReadIntPtr(pcf);
        IntPtr createInst = Marshal.ReadIntPtr(cfvt, 3 * IntPtr.Size);
        var ci = (SlotFn)Marshal.GetDelegateForFunctionPointer(createInst, typeof(SlotFn));

        Guid iidVb = IID_IVirtualBox;
        IntPtr pvb;
        IntPtr ppvSlot = Marshal.AllocHGlobal(IntPtr.Size);
        // CreateInstance(pUnkOuter, riid, ppv) —— 三参，这里借 SlotFn 的前两参不够，
        // 换成三参委托。
        var ci3 = (CreateInstanceFn)Marshal.GetDelegateForFunctionPointer(createInst, typeof(CreateInstanceFn));
        hr = ci3(pcf, IntPtr.Zero, ref iidVb, out pvb);
        Marshal.FreeHGlobal(ppvSlot);
        if (hr != 0) throw new Exception("CreateInstance hr=0x" + hr.ToString("X8"));
        return pvb;
    }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int CreateInstanceFn(IntPtr self, IntPtr pUnkOuter, ref Guid riid, out IntPtr ppv);

    public static IntPtr VtblEntry(IntPtr obj, int idx) {
        IntPtr vt = Marshal.ReadIntPtr(obj);
        return Marshal.ReadIntPtr(vt, idx * IntPtr.Size);
    }

    // 以 (this, BSTR, void**) 形状点一个槽位；返回 HRESULT 与出参
    public static string CallSlot(IntPtr obj, int idx, string bstrArg) {
        IntPtr fn = VtblEntry(obj, idx);
        var f = (SlotFn)Marshal.GetDelegateForFunctionPointer(fn, typeof(SlotFn));

        IntPtr arg = bstrArg == null ? IntPtr.Zero : Marshal.StringToBSTR(bstrArg);
        IntPtr outBuf = Marshal.AllocHGlobal(32);   // 够宽，LONG64/指针都放得下
        for (int i = 0; i < 32; i++) Marshal.WriteByte(outBuf, i, 0);

        int hr;
        try { hr = f(obj, arg, outBuf); }
        catch (Exception e) { Marshal.FreeHGlobal(outBuf); if (arg != IntPtr.Zero) Marshal.FreeBSTR(arg); return "  抛异常: " + e.Message; }

        IntPtr outVal = Marshal.ReadIntPtr(outBuf);
        uint uHr = unchecked((uint)hr);
        string note = "";
        if (uHr == 0x80004001) note = "   <-- E_NOTIMPL（保留属性/保留方法的典型返回）";
        else if (uHr == 0x80004005) note = "   <-- E_FAIL";
        else if (uHr == 0x80070057) note = "   <-- E_INVALIDARG";
        else if (hr == 0) note = "   <-- S_OK";

        string outDesc = outVal == IntPtr.Zero ? "NULL" : ("0x" + outVal.ToInt64().ToString("X"));

        Marshal.FreeHGlobal(outBuf);
        if (arg != IntPtr.Zero) Marshal.FreeBSTR(arg);
        return string.Format("slot[{0,3}] fn={1}  hr=0x{2:X8}{3}  out={4}",
                             idx, "0x" + fn.ToInt64().ToString("X"), uHr, note, outDesc);
    }
}
'@

Add-Type -TypeDefinition $cs -Language CSharp

[void][VBoxProbe]::CoInitializeEx([IntPtr]::Zero, 2)  # STA

$vboxc = "C:\Program Files\Oracle\VirtualBox\VBoxC.dll"
"VBoxC.dll = $vboxc  (存在: $(Test-Path $vboxc))"

$pvb = [VBoxProbe]::CreateRealVBox($vboxc)
"真 IVirtualBox = 0x$($pvb.ToInt64().ToString('X'))"
""

$vmName = "AR_Base"     # 本机确实注册了这台
"=== 传 VM 名 '$vmName' 探两个候选槽 ==="
"两种假说：typelib→[53]=FindMachine / CLAUDE.md→[41]=FindMachine"
""
foreach ($i in 41, 53) {
    [VBoxProbe]::CallSlot($pvb, $i, $vmName)
}
""
"=== 对照：几个已知属性的槽（两种假说下都应正常）==="
foreach ($i in @(7, 11, 13)) {
    [VBoxProbe]::CallSlot($pvb, $i, $null)   # get_version / get_APIVersion / get_homeFolder 均零参
}

# 不做 36..55 的全扫：两种假说对 [38][39][40][50][51][52] 的语义分歧正好落在
# 「单参方法」与「多参方法」之间，拿 BSTR 当对象指针传进去会把探针进程打崩。
# [41]/[53] 是唯一在两个假说下签名都安全的两个槽，且已经足以定案。

[VBoxProbe]::CoUninitialize()
