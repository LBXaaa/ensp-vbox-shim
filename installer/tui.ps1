# tui.ps1 - console interaction layer for the repair menu (mechanism only)
#
# Encoding: pure ASCII, no BOM (library convention, same as checks.ps1 / fix.ps1).
#   This file carries NO user-facing text: every label, prompt and message belongs to the
#   caller (diag.ps1, UTF-8 with BOM, which holds the Chinese), so there is nothing
#   here that needs a non-ASCII byte.
#
# Scope: console capability probe, console mode save/restore, key + mouse event reading,
#   drawing primitives, and the selection loop. No menu, no wording, no policy.
#
# Box-drawing glyphs are deliberately NOT defined here: they are non-ASCII, and a glyph
#   table is data rather than mechanism. The caller passes whatever glyphs it wants to
#   Write-TuiAt. Nothing in this file inspects or filters the text it draws.
#
# ---------------------------------------------------------------------------
# Two independent input channels
# ---------------------------------------------------------------------------
# Keyboard: [Console]::ReadKey($true). Built in, always available, no struct decoding.
#   It throws InvalidOperationException when stdin is redirected - that throw IS the
#   degradation signal, and it is caught here, never propagated.
# Mouse:    P/Invoke, and only the mouse. Enabled solely when a real console was probed.
#   A machine where the mouse path is broken still has a fully working keyboard, and the
#   mouse code can be removed without touching the keyboard path.
# Both normalise into the same event shape, so the menu logic never learns which channel
#   produced an event.
#
# The one thing that forces these two to be sequenced rather than independent:
#   ReadKey and ReadConsoleInput read the SAME console input buffer, and ReadKey throws
#   away every record that is not a key-down (mscorlib Console.ReadKey: it calls
#   ReadConsoleInput, then "continue"s past non-key events; Console.KeyAvailable consumes
#   and discards them too). So a blocking ReadKey silently eats mouse clicks.
#   Hence: while the mouse channel is live, this layer peeks the head record itself
#   (PeekEventType, which consumes nothing) and only calls ReadKey when the head really is
#   a KEY_EVENT. ReadKey then has nothing to discard. Without the mouse channel the plain
#   blocking ReadKey path is used, and there is nothing to lose.
#
# ---------------------------------------------------------------------------
# Facts this design is built on (each one is a way it breaks in practice)
# ---------------------------------------------------------------------------
#   - With stdin redirected, GetStdHandle still returns a handle but GetConsoleMode fails
#     with ERROR_INVALID_HANDLE (6). Probe with GetConsoleMode, never with the handle value.
#   - ENABLE_QUICK_EDIT_MODE must be CLEARED or clicks are consumed by drag-select and never
#     reach the program; that bit is only honoured together with ENABLE_EXTENDED_FLAGS.
#   - The INPUT_RECORD union starts at offset 4, not 2 (union members are DWORD-aligned).
#     The sizes are asserted in Test-TuiLayout below, which runs at load time - a wrong
#     offset shows up there and nowhere else (its runtime symptom is "clicks do nothing").
#   - A key press produces a down AND an up record; only key-down becomes an event.
#   - Colours are set and then restored around each write, so the caller's choice does not
#     leak into whatever is printed next.
#   - Nothing here throws and nothing here hangs: every entry point returns a status or an
#     event, and every native call is checked. Console sizes and positions vary by machine.

$TuiInteropReady = $false
$TuiInteropError = ""
$TuiSavedMode = [uint32]0
$TuiModeEntered = $false
$TuiMouseEnabled = $false
$TuiCursorHidden = $false
$TuiRestoreHook = $false

$TuiSource = @'
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public struct COORD { public short X; public short Y; }

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct KEY_EVENT_RECORD {
    public int bKeyDown;          // BOOL
    public ushort wRepeatCount;
    public ushort wVirtualKeyCode;
    public ushort wVirtualScanCode;
    public char UnicodeChar;
    public uint dwControlKeyState;
}

[StructLayout(LayoutKind.Sequential)]
public struct MOUSE_EVENT_RECORD {
    public COORD dwMousePosition;
    public uint dwButtonState;
    public uint dwControlKeyState;
    public uint dwEventFlags;
}

[StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
public struct INPUT_RECORD {
    [FieldOffset(0)] public ushort EventType;
    [FieldOffset(4)] public KEY_EVENT_RECORD   KeyEvent;
    [FieldOffset(4)] public MOUSE_EVENT_RECORD MouseEvent;
}

public static class TuiNative
{
    public const int STD_INPUT_HANDLE  = -10;
    public const int STD_OUTPUT_HANDLE = -11;

    public const uint ENABLE_WINDOW_INPUT    = 0x0008;
    public const uint ENABLE_MOUSE_INPUT     = 0x0010;
    public const uint ENABLE_QUICK_EDIT_MODE = 0x0040;
    public const uint ENABLE_EXTENDED_FLAGS  = 0x0080;

    public const ushort KEY_EVENT                = 0x0001;
    public const ushort MOUSE_EVENT              = 0x0002;
    public const ushort WINDOW_BUFFER_SIZE_EVENT = 0x0004;

    public const int WAIT_OBJECT_0 = 0;
    public const int WAIT_TIMEOUT  = 258;

    public const int ERROR_SUCCESS        = 0;
    public const int ERROR_INVALID_HANDLE = 6;

    public static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool PeekConsoleInput(IntPtr hConsoleInput, IntPtr lpBuffer, uint nLength, out uint lpNumberOfEventsRead);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadConsoleInput(IntPtr hConsoleInput, IntPtr lpBuffer, uint nLength, out uint lpNumberOfEventsRead);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FlushConsoleInputBuffer(IntPtr hConsoleInput);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern int WaitForSingleObject(IntPtr hHandle, int dwMilliseconds);

    private static IntPtr InputHandle()
    {
        IntPtr h = GetStdHandle(STD_INPUT_HANDLE);
        if (h == IntPtr.Zero || h == INVALID_HANDLE_VALUE) return IntPtr.Zero;
        return h;
    }

    private static int LastError()
    {
        int e = Marshal.GetLastWin32Error();
        return e == 0 ? ERROR_INVALID_HANDLE : e;
    }

    // 0 = stdin is a real console. Otherwise the Win32 error (6 when redirected).
    public static int ProbeInput()
    {
        IntPtr h = InputHandle();
        if (h == IntPtr.Zero) return ERROR_INVALID_HANDLE;
        uint mode;
        if (!GetConsoleMode(h, out mode)) return LastError();
        return ERROR_SUCCESS;
    }

    public static int GetInputMode(out uint mode)
    {
        mode = 0;
        IntPtr h = InputHandle();
        if (h == IntPtr.Zero) return ERROR_INVALID_HANDLE;
        if (!GetConsoleMode(h, out mode)) return LastError();
        return ERROR_SUCCESS;
    }

    public static int SetInputMode(uint mode)
    {
        IntPtr h = InputHandle();
        if (h == IntPtr.Zero) return ERROR_INVALID_HANDLE;
        if (!SetConsoleMode(h, mode)) return LastError();
        return ERROR_SUCCESS;
    }

    // Event type of the record at the head of the input queue, WITHOUT consuming it.
    // 0 = ok (type 0 means the queue is empty), otherwise the Win32 error.
    public static int PeekEventType(out ushort eventType)
    {
        eventType = 0;
        IntPtr h = InputHandle();
        if (h == IntPtr.Zero) return ERROR_INVALID_HANDLE;
        int size = Marshal.SizeOf(typeof(INPUT_RECORD));
        IntPtr buf = Marshal.AllocHGlobal(size);
        try
        {
            uint read = 0;
            if (!PeekConsoleInput(h, buf, 1, out read)) return LastError();
            if (read == 0) return ERROR_SUCCESS;
            INPUT_RECORD rec = (INPUT_RECORD)Marshal.PtrToStructure(buf, typeof(INPUT_RECORD));
            eventType = rec.EventType;
            return ERROR_SUCCESS;
        }
        finally
        {
            Marshal.FreeHGlobal(buf);
        }
    }

    // Consume the record at the head of the input queue. Callers peek first and never call
    // this when the head is a KEY_EVENT, so keys stay for the built-in reader.
    public static int ReadHeadRecord(out INPUT_RECORD record)
    {
        record = new INPUT_RECORD();
        IntPtr h = InputHandle();
        if (h == IntPtr.Zero) return ERROR_INVALID_HANDLE;
        int size = Marshal.SizeOf(typeof(INPUT_RECORD));
        IntPtr buf = Marshal.AllocHGlobal(size);
        try
        {
            uint read = 0;
            if (!ReadConsoleInput(h, buf, 1, out read)) return LastError();
            if (read == 0) return ERROR_INVALID_HANDLE;
            record = (INPUT_RECORD)Marshal.PtrToStructure(buf, typeof(INPUT_RECORD));
            return ERROR_SUCCESS;
        }
        finally
        {
            Marshal.FreeHGlobal(buf);
        }
    }

    // Wait until console input is available or the timeout expires.
    // 0 = signalled, 258 = WAIT_TIMEOUT, anything else = failure. timeoutMs < 0 = infinite.
    public static int WaitInput(int timeoutMs)
    {
        IntPtr h = InputHandle();
        if (h == IntPtr.Zero) return ERROR_INVALID_HANDLE;
        return WaitForSingleObject(h, timeoutMs);
    }

    public static int FlushInput()
    {
        IntPtr h = InputHandle();
        if (h == IntPtr.Zero) return ERROR_INVALID_HANDLE;
        if (!FlushConsoleInputBuffer(h)) return LastError();
        return ERROR_SUCCESS;
    }
}
'@

try {
    if (-not ("TuiNative" -as [type])) {
        Add-Type -TypeDefinition $TuiSource -Language CSharp -ErrorAction Stop
    }
    $TuiInteropReady = [bool]("TuiNative" -as [type])
} catch {
    $TuiInteropReady = $false
    $TuiInteropError = $_.Exception.Message
}

# ---------------------------------------------------------------------------
# Layout self-check
#
# Get the INPUT_RECORD union offset wrong and every mouse event is read from the wrong
# bytes, which surfaces to the user as "clicking does nothing" and to the developer as
# nothing at all. Marshal.SizeOf is the only place that shows it, so it is checked once
# at load time instead of being assumed.
# Expected: COORD 4, KEY_EVENT_RECORD 16, MOUSE_EVENT_RECORD 16, INPUT_RECORD 20.
# ---------------------------------------------------------------------------
function Test-TuiLayout {
    if (-not $TuiInteropReady) { return $false }
    try {
        if ([Runtime.InteropServices.Marshal]::SizeOf([type][COORD]) -ne 4) { return $false }
        if ([Runtime.InteropServices.Marshal]::SizeOf([type][KEY_EVENT_RECORD]) -ne 16) { return $false }
        if ([Runtime.InteropServices.Marshal]::SizeOf([type][MOUSE_EVENT_RECORD]) -ne 16) { return $false }
        if ([Runtime.InteropServices.Marshal]::SizeOf([type][INPUT_RECORD]) -ne 20) { return $false }
        return $true
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Capability probe
# ---------------------------------------------------------------------------

# $true only when stdin is a real console. Never throws, never blocks.
function Test-TuiConsoleAvailable {
    if (-not $TuiInteropReady) { return $false }
    try {
        return ([TuiNative]::ProbeInput() -eq 0)
    } catch {
        return $false
    }
}

# Probe results as data, so the caller can explain a degraded run instead of silently
# dropping into keyboard-only mode (the design requires that fallback to be visible).
function Get-TuiStatus {
    $console = $false
    $probeError = -1
    if ($TuiInteropReady) {
        try {
            $probeError = [TuiNative]::ProbeInput()
            $console = ($probeError -eq 0)
        } catch {
            $probeError = -1
        }
    }
    $size = Get-TuiSize
    return [pscustomobject]@{
        InteropReady  = [bool]$TuiInteropReady
        InteropError  = $TuiInteropError
        LayoutOk      = (Test-TuiLayout)
        ConsoleOk     = $console
        ProbeError    = $probeError
        MouseEnabled  = [bool]$TuiMouseEnabled
        ModeEntered   = [bool]$TuiModeEntered
        Drawable      = [bool]$size.Ok
        Width         = [int]$size.Width
        Height        = [int]$size.Height
    }
}

# ---------------------------------------------------------------------------
# Mode: enter / leave / restore
# ---------------------------------------------------------------------------

# Turn on mouse input and turn OFF quick-edit for this console, saving what was there.
# Returns $true only when a real console was found AND the mode was changed. With no
# console nothing at all is touched - the caller keeps keyboard-only operation.
function Enter-TuiMode {
    if (-not (Test-TuiConsoleAvailable)) { return $false }

    $mode = [uint32]0
    $err = 1
    try { $err = [TuiNative]::GetInputMode([ref]$mode) } catch { return $false }
    if ($err -ne 0) { return $false }

    # Saved before the change: this exact value is what Exit-TuiMode puts back.
    $script:TuiSavedMode = [uint32]$mode

    # Mouse and window (resize) events on, quick-edit off. ENABLE_EXTENDED_FLAGS is set
    # because the quick-edit bit is only honoured when it is present; clearing quick-edit
    # is what makes clicks reach the program instead of starting a drag-select.
    $m = [int]$mode
    $m = $m -bor 0x0010 -bor 0x0008 -bor 0x0080
    $m = $m -band (-bnot 0x0040)

    $err = 1
    try { $err = [TuiNative]::SetInputMode([uint32]$m) } catch { $err = 1 }
    if ($err -ne 0) { return $false }

    $script:TuiModeEntered = $true
    $script:TuiMouseEnabled = $true

    # Hiding the cursor is cosmetic and must never be able to fail the mode change.
    try {
        if ([Console]::CursorVisible) {
            [Console]::CursorVisible = $false
            $script:TuiCursorHidden = $true
        }
    } catch { }

    Register-TuiRestoreHook
    return $true
}

# Restore what Enter-TuiMode saved. Safe to call when nothing was entered, safe to call
# more than once, never throws. The caller should also call this from its own error paths -
# only the restore path is critical here: leaving a window with quick-edit off means the
# user can no longer drag-select in it, with no way to tell why.
function Exit-TuiMode {
    if ($TuiModeEntered) {
        try { [void][TuiNative]::SetInputMode([uint32]$TuiSavedMode) } catch { }
        $script:TuiModeEntered = $false
    }
    if ($TuiCursorHidden) {
        try { [Console]::CursorVisible = $true } catch { }
        $script:TuiCursorHidden = $false
    }
    $script:TuiMouseEnabled = $false
}

# Explicit name for the caller's error paths, so intent is readable at the call site.
function Restore-TuiMode {
    Exit-TuiMode
}

# Best-effort restore if the session ends while the mode is still altered. This cannot
# cover TerminateProcess or a killed console, only a normal PowerShell exit - the reliable
# path remains the caller's finally block. Registered once.
function Register-TuiRestoreHook {
    if ($TuiRestoreHook) { return }
    $script:TuiRestoreHook = $true
    $saved = [int]$TuiSavedMode
    try {
        $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -SupportEvent -MessageData $saved -Action {
            try {
                $m = [int]$event.MessageData
                if ($m -ne 0) { [void][TuiNative]::SetInputMode([uint32]$m) }
            } catch { }
        }
    } catch { }
}

# ---------------------------------------------------------------------------
# Event reading
# ---------------------------------------------------------------------------

# Read a key through the built-in reader. InvalidOperationException here means stdin is
# redirected or the console went away - reported as EOF so callers unwind instead of
# spinning. Never returns $null.
function Read-TuiKeyEvent {
    $k = $null
    try { $k = [Console]::ReadKey($true) } catch { return @{ Kind = "eof" } }
    if ($null -eq $k) { return @{ Kind = "eof" } }

    $name = "Other"
    switch ([string]$k.Key) {
        "UpArrow"    { $name = "Up" }
        "DownArrow"  { $name = "Down" }
        "LeftArrow"  { $name = "Left" }
        "RightArrow" { $name = "Right" }
        "Enter"      { $name = "Enter" }
        "Escape"     { $name = "Esc" }
    }

    $ch = ""
    if ($name -eq "Other") {
        $c = $k.KeyChar
        if ($c -and (-not [char]::IsControl($c))) {
            $name = "Char"
            $ch = [string]$c
        }
    }
    return @{ Kind = "key"; Key = $name; Char = $ch; Modifiers = [string]$k.Modifiers }
}

# Normalise one raw INPUT_RECORD. This is the only place a record becomes an event.
# It is used in production for every non-key record the mouse channel consumes
# (MOUSE_EVENT, WINDOW_BUFFER_SIZE_EVENT, focus); the KEY_EVENT arm is the same
# translation for a record-shaped key, and is what the layout/normalisation self-test
# drives with hand-built structs.
function ConvertFrom-TuiRecord {
    param([Parameter(Mandatory = $true)]$Record)

    $type = [int]$Record.EventType

    if ($type -eq 1) {
        $key = $Record.KeyEvent
        # A key press arrives twice (down, then up). Only key-down is an event; returning
        # both would make every keystroke act twice.
        if ([int]$key.bKeyDown -eq 0) { return @{ Kind = "none" } }

        $name = "Other"
        switch ([int]$key.wVirtualKeyCode) {
            0x26 { $name = "Up" }
            0x28 { $name = "Down" }
            0x25 { $name = "Left" }
            0x27 { $name = "Right" }
            0x0D { $name = "Enter" }
            0x1B { $name = "Esc" }
        }
        $ch = ""
        if ($name -eq "Other") {
            $c = [char]$key.UnicodeChar
            if ($c -and (-not [char]::IsControl($c))) {
                $name = "Char"
                $ch = [string]$c
            }
        }
        return @{ Kind = "key"; Key = $name; Char = $ch; Modifiers = "" }
    }

    if ($type -eq 2) {
        $mouse = $Record.MouseEvent
        $flags = [int64]$mouse.dwEventFlags
        $buttons = [int64]$mouse.dwButtonState
        $x = [int]$mouse.dwMousePosition.X
        $y = [int]$mouse.dwMousePosition.Y

        if (($flags -band 0x0004) -ne 0) {
            # Wheel: the delta is the SIGNED high word of dwButtonState.
            $delta = [int](($buttons -shr 16) -band 0xFFFF)
            if ($delta -ge 0x8000) { $delta = $delta - 0x10000 }
            $wheel = "Down"
            if ($delta -gt 0) { $wheel = "Up" }
            return @{ Kind = "mouse"; X = $x; Y = $y; Button = "None"; Wheel = $wheel }
        }

        # Movement is not actionable (the caller redraws on selection change, not on hover).
        if (($flags -band 0x0001) -ne 0) { return @{ Kind = "none" } }

        if (($buttons -band 0x0001) -ne 0) {
            return @{ Kind = "mouse"; X = $x; Y = $y; Button = "Left"; Wheel = "None" }
        }
        # Release (and any non-left button): reported, but with no button held, so a caller
        # switching on Button = "Left" sees exactly one event per click.
        return @{ Kind = "mouse"; X = $x; Y = $y; Button = "None"; Wheel = "None" }
    }

    if ($type -eq 4) { return @{ Kind = "resize" } }

    return @{ Kind = "none" }
}

# One normalised event.
#   @{ Kind = "key";    Key = "Up"|"Down"|"Left"|"Right"|"Enter"|"Esc"|"Char"|"Other"; Char = ""; Modifiers = "" }
#   @{ Kind = "mouse";  X = <int>; Y = <int>; Button = "Left"|"None"; Wheel = "Up"|"Down"|"None" }
#   @{ Kind = "resize" }
#   @{ Kind = "none" }     - a real record with nothing actionable in it (key-up, movement)
#   @{ Kind = "eof" }      - no usable console, or the console went away; callers must stop
#   @{ Kind = "timeout" }  - -TimeoutMs expired with no input
#
# -TimeoutMs bounds the wait for one record; 0 blocks until something arrives. Returns
# rather than looping when the console is gone, so a caller can never be left spinning.
function Read-TuiEvent {
    param([int]$TimeoutMs = 0)

    if (-not (Test-TuiConsoleAvailable)) { return @{ Kind = "eof" } }

    $useMouse = [bool]$TuiMouseEnabled
    $deadline = 0
    if ($TimeoutMs -gt 0) { $deadline = [Environment]::TickCount + $TimeoutMs }

    while ($true) {
        # No mouse channel and no deadline: hand over to the plain blocking reader.
        # Nothing can be lost here, because nothing else is listening.
        if ((-not $useMouse) -and ($TimeoutMs -le 0)) {
            return (Read-TuiKeyEvent)
        }

        $type = [uint16]0
        $rc = 1
        try { $rc = [TuiNative]::PeekEventType([ref]$type) } catch { return @{ Kind = "eof" } }
        if ($rc -ne 0) { return @{ Kind = "eof" } }

        if ($type -eq 0) {
            # Nothing pending. Wait without consuming anything.
            $wait = -1
            if ($TimeoutMs -gt 0) {
                $wait = $deadline - [Environment]::TickCount
                if ($wait -le 0) { return @{ Kind = "timeout" } }
            }
            $wr = -1
            try { $wr = [TuiNative]::WaitInput($wait) } catch { return @{ Kind = "eof" } }
            if ($wr -eq 258) { return @{ Kind = "timeout" } }
            if ($wr -ne 0) { return @{ Kind = "eof" } }
            continue
        }

        # The head is a key: the built-in reader can take it without discarding anything.
        if ($type -eq 1) { return (Read-TuiKeyEvent) }

        # Any other record (mouse, resize, focus) is ours to consume.
        $rec = New-Object INPUT_RECORD
        $rc = 1
        try { $rc = [TuiNative]::ReadHeadRecord([ref]$rec) } catch { return @{ Kind = "eof" } }
        if ($rc -ne 0) { return @{ Kind = "eof" } }

        $ev = ConvertFrom-TuiRecord -Record $rec
        if ((-not $useMouse) -and ($ev.Kind -eq "mouse")) { continue }
        return $ev
    }
}

# Discard anything still queued (a click's release record, a buffered key from a
# double-press). Called when a choice is returned, so leftovers cannot answer the caller's
# next question by themselves.
function Clear-TuiInput {
    if (-not $TuiInteropReady) { return $false }
    try { return ([TuiNative]::FlushInput() -eq 0) } catch { return $false }
}

# ---------------------------------------------------------------------------
# Drawing
#
# All of it goes through [Console] with clamping and try/finally, so a position outside
# the buffer or a console that vanished is a no-op, never an exception. Clear-Host is
# deliberately not used anywhere: it would take the scrollback with it, and the report the
# user may still want to read is above the menu.
# ---------------------------------------------------------------------------

# Current console metrics. Width/Height are the visible window; BufferWidth/BufferHeight
# are the drawable buffer, which is what drawing has to be clamped against. Ok = $false
# means nothing can be drawn (no console on stdout) - the caller can say so out loud.
function Get-TuiSize {
    try {
        return [pscustomobject]@{
            Ok           = $true
            Width        = [int][Console]::WindowWidth
            Height       = [int][Console]::WindowHeight
            BufferWidth  = [int][Console]::BufferWidth
            BufferHeight = [int][Console]::BufferHeight
            Left         = [int][Console]::WindowLeft
            Top          = [int][Console]::WindowTop
            CursorX      = [int][Console]::CursorLeft
            CursorY      = [int][Console]::CursorTop
        }
    } catch {
        return [pscustomobject]@{
            Ok           = $false
            Width        = 80
            Height       = 25
            BufferWidth  = 80
            BufferHeight = 25
            Left         = 0
            Top          = 0
            CursorX      = 0
            CursorY      = 0
        }
    }
}

# Move the cursor. The position is clamped into the buffer; $false means there is no
# console to move it on.
function Set-TuiCursor {
    param([int]$X = 0, [int]$Y = 0)

    $size = Get-TuiSize
    if (-not $size.Ok) { return $false }
    $cx = [Math]::Min([Math]::Max($X, 0), [Math]::Max($size.BufferWidth - 1, 0))
    $cy = [Math]::Min([Math]::Max($Y, 0), [Math]::Max($size.BufferHeight - 1, 0))
    try {
        [Console]::SetCursorPosition($cx, $cy)
        return $true
    } catch {
        return $false
    }
}

# Draw one string at a position. -Color / -BackColor are optional; when omitted the
# console's current values are used. Either way they are restored after the write, so a
# caller's colour never leaks into later output.
# Text is clipped to the end of the row rather than wrapped, because wrapping would
# overwrite the next line of the caller's layout. Wide (CJK) glyphs still occupy two cells
# and can wrap early - keeping lines inside the window is the caller's job.
# Returns $false when the position is outside the buffer or there is no console; the
# request is skipped, never clamped into a different place than the caller asked for.
function Write-TuiAt {
    param(
        [int]$X = 0,
        [int]$Y = 0,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text = "",
        [ConsoleColor]$Color = [ConsoleColor]::Gray,
        [ConsoleColor]$BackColor = [ConsoleColor]::Black
    )

    if ($Text.Length -eq 0) { return $false }

    $size = Get-TuiSize
    if (-not $size.Ok) { return $false }
    if ($X -lt 0 -or $Y -lt 0 -or $X -ge $size.BufferWidth -or $Y -ge $size.BufferHeight) { return $false }

    $max = $size.BufferWidth - $X
    $s = $Text
    if ($s.Length -gt $max) { $s = $s.Substring(0, $max) }
    if ($s.Length -eq 0) { return $false }

    $setFg = $PSBoundParameters.ContainsKey("Color")
    $setBg = $PSBoundParameters.ContainsKey("BackColor")

    try {
        [Console]::SetCursorPosition($X, $Y)
        $oldFg = [Console]::ForegroundColor
        $oldBg = [Console]::BackgroundColor
        try {
            if ($setFg) { [Console]::ForegroundColor = $Color }
            if ($setBg) { [Console]::BackgroundColor = $BackColor }
            [Console]::Write($s)
        } finally {
            if ($setFg) { [Console]::ForegroundColor = $oldFg }
            if ($setBg) { [Console]::BackgroundColor = $oldBg }
        }
        return $true
    } catch {
        return $false
    }
}

# Blank a rectangle. The region is clipped to the buffer, so an oversized request clears
# what exists instead of failing.
function Clear-TuiRegion {
    param(
        [int]$X = 0,
        [int]$Y = 0,
        [int]$W = 0,
        [int]$H = 0,
        [ConsoleColor]$Color = [ConsoleColor]::Gray,
        [ConsoleColor]$BackColor = [ConsoleColor]::Black
    )

    if ($W -le 0 -or $H -le 0) { return $false }

    $size = Get-TuiSize
    if (-not $size.Ok) { return $false }

    $x0 = [Math]::Max($X, 0)
    $y0 = [Math]::Max($Y, 0)
    $x1 = [Math]::Min($X + $W - 1, $size.BufferWidth - 1)
    $y1 = [Math]::Min($Y + $H - 1, $size.BufferHeight - 1)
    if ($x1 -lt $x0 -or $y1 -lt $y0) { return $false }

    $blank = " " * ($x1 - $x0 + 1)
    $any = $false
    for ($y = $y0; $y -le $y1; $y++) {
        $rowArgs = @{ X = $x0; Y = $y; Text = $blank }
        if ($PSBoundParameters.ContainsKey("Color")) { $rowArgs["Color"] = $Color }
        if ($PSBoundParameters.ContainsKey("BackColor")) { $rowArgs["BackColor"] = $BackColor }
        if (Write-TuiAt @rowArgs) { $any = $true }
    }
    return $any
}

# ---------------------------------------------------------------------------
# Selection loop
# ---------------------------------------------------------------------------

function New-TuiResult {
    param(
        [string]$Action = "none",
        [int]$Index = -1,
        [string]$Char = "",
        [string]$Key = "",
        [string]$Wheel = "None"
    )
    return [pscustomobject]@{
        Action = $Action
        Index  = $Index
        Char   = $Char
        Key    = $Key
        Wheel  = $Wheel
    }
}

# Own the loop, let the caller own the pixels.
#
#   -RenderScript   scriptblock(selectionIndex) -> paints. Called once up front and then
#                   only when the selection actually changed (or on a resize).
#   -KeyMap         optional @{ "A" = "all" } - a letter key becomes Action = that string.
#   -MouseHitTest   optional scriptblock(X, Y) -> 0-based item index, or -1 for a miss.
#                   Passed only if clicks should select; omit it and clicks are ignored.
#   -TimeoutMs      0 = wait indefinitely for input. > 0 = give up after that long and
#                   return Action = "timeout". Never blocks past the deadline.
#   -EventSource    optional scriptblock returning the next event object. Supplying it
#                   replaces the console entirely, which is what makes this loop testable
#                   without a terminal.
#
# Returns @{ Action; Index; Char; Key; Wheel } with Action:
#   "select"  Index is the chosen item (0-based)
#   "cancel"  Esc, or the digit 0
#   "eof"     no usable console, console lost, or input ended
#   "timeout" -TimeoutMs expired
#   "key"     an unmapped printable character; Char holds it
#   <string>  a value from -KeyMap; Char holds the key that produced it
function Read-TuiChoice {
    param(
        [int]$ItemCount = 0,
        [scriptblock]$RenderScript = $null,
        [hashtable]$KeyMap = $null,
        [scriptblock]$MouseHitTest = $null,
        [int]$TimeoutMs = 0,
        [int]$StartIndex = 0,
        [scriptblock]$EventSource = $null
    )

    if ($ItemCount -le 0) { return (New-TuiResult -Action "cancel") }

    $index = $StartIndex
    if ($index -lt 0) { $index = 0 }
    if ($index -gt ($ItemCount - 1)) { $index = $ItemCount - 1 }

    $drawn = -1
    $deadline = 0
    if ($TimeoutMs -gt 0) { $deadline = [Environment]::TickCount + $TimeoutMs }

    while ($true) {
        if ($drawn -ne $index) {
            if ($RenderScript) {
                try { & $RenderScript $index } catch { }
            }
            $drawn = $index
        }

        $ev = $null
        if ($EventSource) {
            try { $ev = & $EventSource } catch { $ev = $null }
            if ($null -eq $ev) { return (New-TuiResult -Action "eof" -Index $index) }
        } else {
            $left = $TimeoutMs
            if ($TimeoutMs -gt 0) {
                $left = $deadline - [Environment]::TickCount
                if ($left -le 0) { return (New-TuiResult -Action "timeout" -Index $index) }
            }
            $ev = Read-TuiEvent -TimeoutMs $left
        }

        $kind = [string]$ev.Kind
        if ($kind -eq "eof") { return (New-TuiResult -Action "eof" -Index $index) }
        if ($kind -eq "timeout") { return (New-TuiResult -Action "timeout" -Index $index) }
        if ($kind -eq "none") { continue }
        if ($kind -eq "resize") { $drawn = -1; continue }

        if ($kind -eq "mouse") {
            if ($ev.Wheel -eq "Up") {
                $index = $index - 1
                if ($index -lt 0) { $index = $ItemCount - 1 }
                continue
            }
            if ($ev.Wheel -eq "Down") {
                $index = $index + 1
                if ($index -ge $ItemCount) { $index = 0 }
                continue
            }
            if ($ev.Button -ne "Left") { continue }
            if (-not $MouseHitTest) { continue }
            $hit = -1
            try { $hit = [int](& $MouseHitTest $ev.X $ev.Y) } catch { $hit = -1 }
            if ($hit -ge 0 -and $hit -lt $ItemCount) {
                Clear-TuiInput
                return (New-TuiResult -Action "select" -Index $hit)
            }
            continue
        }

        if ($kind -ne "key") { continue }

        $key = [string]$ev.Key
        if ($key -eq "Up" -or $key -eq "Left") {
            $index = $index - 1
            if ($index -lt 0) { $index = $ItemCount - 1 }
            continue
        }
        if ($key -eq "Down" -or $key -eq "Right") {
            $index = $index + 1
            if ($index -ge $ItemCount) { $index = 0 }
            continue
        }
        if ($key -eq "Enter") {
            Clear-TuiInput
            return (New-TuiResult -Action "select" -Index $index)
        }
        if ($key -eq "Esc") {
            Clear-TuiInput
            return (New-TuiResult -Action "cancel" -Index $index)
        }
        if ($key -ne "Char") { continue }

        $c = [string]$ev.Char
        if ($c -eq "0") {
            Clear-TuiInput
            return (New-TuiResult -Action "cancel" -Index $index -Char $c)
        }
        if ($c -match '^[1-9]$') {
            $n = [int]$c
            if ($n -le $ItemCount) {
                Clear-TuiInput
                return (New-TuiResult -Action "select" -Index ($n - 1) -Char $c)
            }
        }

        $mapped = $null
        if ($KeyMap) {
            if ($KeyMap.ContainsKey($c)) { $mapped = $KeyMap[$c] }
            elseif ($KeyMap.ContainsKey($c.ToUpperInvariant())) { $mapped = $KeyMap[$c.ToUpperInvariant()] }
        }
        Clear-TuiInput
        if ($null -ne $mapped) {
            return (New-TuiResult -Action ([string]$mapped) -Index $index -Char $c -Key $key)
        }
        return (New-TuiResult -Action "key" -Index $index -Char $c -Key $key)
    }
}
