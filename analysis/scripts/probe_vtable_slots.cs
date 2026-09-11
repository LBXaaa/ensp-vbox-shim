// probe_vtable_slots.cs — 在活的 VirtualBox 7.2 IVirtualBox 上直接点 vtable 槽位
//
// 判定目标：7.2.8 IVirtualBox 的方法区究竟从索引 36 起还是 48 起。
//   analysis/output/vbox728_vtable.md（typelib 解析）: 48 起 → [53]=FindMachine, [41]=保留属性
//   CLAUDE.md 表                                     : 36 起 → [41]=FindMachine, [53]=getExtraDataKeys
//
// 绕过注册表（本机 CLSID 被垫片劫持）：
//   LoadLibrary(Oracle 原版 VBoxC.dll) → DllGetClassObject → IClassFactory::CreateInstance
//
// 判据：传一个确实存在的 VM 名。真 FindMachine → S_OK 且出参非空；
//       InternalAndReservedAttributeN 的实现返回 E_NOTIMPL (0x80004001)。

using System;
using System.Runtime.InteropServices;

static class VBoxProbe {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr LoadLibraryW(string p);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    static extern IntPtr GetProcAddress(IntPtr h, string n);
    [DllImport("ole32.dll")] static extern int CoInitializeEx(IntPtr p, uint f);
    [DllImport("ole32.dll")] static extern void CoUninitialize();

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int DllGetClassObjectFn(ref Guid clsid, ref Guid riid, out IntPtr ppv);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int CreateInstanceFn(IntPtr self, IntPtr outer, ref Guid riid, out IntPtr ppv);
    // 通用槽位形状：(this, arg1, out) —— 覆盖零参 getter、单参方法、以及 (ULONG*) 保留属性
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int SlotFn(IntPtr self, IntPtr arg, IntPtr outPtr);

    static readonly Guid CLSID_VirtualBox = new Guid("B1A7A4F2-47B9-4A1E-82B2-07CCD5323C3F");
    static readonly Guid IID_IClassFactory = new Guid("00000001-0000-0000-C000-000000000046");
    static readonly Guid IID_IVirtualBox   = new Guid("2CE10519-3C09-45D8-A12D-E887786146B7");

    static IntPtr VtblEntry(IntPtr obj, int idx) {
        IntPtr vt = Marshal.ReadIntPtr(obj);
        return Marshal.ReadIntPtr(vt, idx * IntPtr.Size);
    }

    static IntPtr CreateRealVBox(string path) {
        IntPtr h = LoadLibraryW(path);
        if (h == IntPtr.Zero) throw new Exception("LoadLibrary 失败 err=" + Marshal.GetLastWin32Error());
        IntPtr pfn = GetProcAddress(h, "DllGetClassObject");
        if (pfn == IntPtr.Zero) throw new Exception("无 DllGetClassObject");
        var dgco = (DllGetClassObjectFn)Marshal.GetDelegateForFunctionPointer(pfn, typeof(DllGetClassObjectFn));

        Guid clsid = CLSID_VirtualBox, iidCf = IID_IClassFactory;
        IntPtr pcf;
        int hr = dgco(ref clsid, ref iidCf, out pcf);
        if (hr != 0) throw new Exception("DllGetClassObject hr=0x" + ((uint)hr).ToString("X8"));

        IntPtr createInst = VtblEntry(pcf, 3);   // IClassFactory::CreateInstance
        var ci = (CreateInstanceFn)Marshal.GetDelegateForFunctionPointer(createInst, typeof(CreateInstanceFn));
        Guid iidVb = IID_IVirtualBox;
        IntPtr pvb;
        hr = ci(pcf, IntPtr.Zero, ref iidVb, out pvb);
        if (hr != 0) throw new Exception("CreateInstance hr=0x" + ((uint)hr).ToString("X8"));
        return pvb;
    }

    static void CallSlot(IntPtr obj, int idx, string bstrArg) {
        IntPtr fn = VtblEntry(obj, idx);
        var f = (SlotFn)Marshal.GetDelegateForFunctionPointer(fn, typeof(SlotFn));

        IntPtr arg = (bstrArg == null) ? IntPtr.Zero : Marshal.StringToBSTR(bstrArg);
        IntPtr outBuf = Marshal.AllocHGlobal(32);
        for (int i = 0; i < 32; i++) Marshal.WriteByte(outBuf, i, 0);

        int hr;
        try {
            hr = f(obj, arg, outBuf);
        } catch (Exception e) {
            Console.WriteLine("slot[{0,3}] 抛异常: {1}", idx, e.Message);
            Marshal.FreeHGlobal(outBuf);
            if (arg != IntPtr.Zero) Marshal.FreeBSTR(arg);
            return;
        }

        uint uHr = unchecked((uint)hr);
        IntPtr outVal = Marshal.ReadIntPtr(outBuf);
        // 出参若是 BSTR，顺手解出来看看（只读，不解引用可疑指针）
        string outDesc = outVal == IntPtr.Zero ? "NULL" : ("0x" + outVal.ToInt64().ToString("X"));

        string note = "";
        if (uHr == 0x80004001) note = "  <== E_NOTIMPL";
        else if (uHr == 0x80004005) note = "  <== E_FAIL";
        else if (uHr == 0x80070057) note = "  <== E_INVALIDARG";
        else if (uHr == 0x80070005) note = "  <== E_ACCESSDENIED";
        else if (hr == 0) note = "  <== S_OK";

        Console.WriteLine("slot[{0,3}] fn=0x{1}  hr=0x{2:X8}{3}  out={4}",
                          idx, fn.ToInt64().ToString("X"), uHr, note, outDesc);

        Marshal.FreeHGlobal(outBuf);
        if (arg != IntPtr.Zero) Marshal.FreeBSTR(arg);
    }

    static int Main(string[] args) {
        string vboxc = @"C:\Program Files\Oracle\VirtualBox\VBoxC.dll";
        string vmName = args.Length > 0 ? args[0] : "AR_Base";

        CoInitializeEx(IntPtr.Zero, 2);   // STA
        Console.WriteLine("VBoxC.dll = " + vboxc);

        IntPtr pvb;
        try { pvb = CreateRealVBox(vboxc); }
        catch (Exception e) { Console.WriteLine("拿真对象失败: " + e.Message); CoUninitialize(); return 2; }
        Console.WriteLine("真 IVirtualBox = 0x" + pvb.ToInt64().ToString("X"));
        Console.WriteLine();

        Console.WriteLine("=== 对照：已知属性槽（两种假说下都应是 BSTR getter）===");
        CallSlot(pvb, 7, null);    // Version
        CallSlot(pvb, 11, null);   // APIVersion
        CallSlot(pvb, 13, null);   // HomeFolder
        Console.WriteLine();

        Console.WriteLine("=== 决定性：传 VM 名 '" + vmName + "' ===");
        Console.WriteLine("   typelib 假说 → [53]=FindMachine 应 S_OK；[41]=保留属性 应 E_NOTIMPL");
        Console.WriteLine("   CLAUDE.md 假说 → [41]=FindMachine 应 S_OK；[53]=getExtraDataKeys 应非 S_OK 或空");
        CallSlot(pvb, 41, vmName);
        CallSlot(pvb, 53, vmName);
        Console.WriteLine();

        Console.WriteLine("=== 补一个零参对照：[53] 若真是 getExtraDataKeys，零参调用也应工作 ===");
        CallSlot(pvb, 53, null);
        CallSlot(pvb, 41, null);

        CoUninitialize();
        return 0;
    }
}
