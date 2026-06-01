@echo off
REM ============================================================================
REM  Build VBox52.dll  -- the eNSP <-> VirtualBox 7.x compatibility shim.
REM
REM  Requires a 32-bit MSVC toolchain (ml.exe / cl.exe / link.exe). eNSP loads
REM  this DLL into the 32-bit eNSP_VBoxServer.exe, so it MUST be built x86.
REM
REM  Adjust the vcvars32.bat path below to match your Visual Studio install
REM  (this default is VS 2026 / v18 Community). Output: build\VBox52.dll
REM ============================================================================
setlocal
pushd "%~dp0"
set "SRC=..\src"
set "VCVARS=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars32.bat"

if not exist "%VCVARS%" (
  echo [!] vcvars32.bat not found at "%VCVARS%"
  echo     Edit the VCVARS path in this script to point at your VS install.
  popd & endlocal & exit /b 1
)
call "%VCVARS%"
if %errorlevel% neq 0 (echo vcvars32 FAILED & popd & endlocal & exit /b %errorlevel%)

echo === Assembling thunks ===
ml.exe /c /coff /Cx /Fovbox52_thunks.obj "%SRC%\vbox52_thunks.asm"
if %errorlevel% neq 0 (echo ML FAILED & popd & endlocal & exit /b %errorlevel%)
ml.exe /c /coff /Cx /Foimachine_entries.obj "%SRC%\imachine_entries.asm"
if %errorlevel% neq 0 (echo ML FAILED & popd & endlocal & exit /b %errorlevel%)

echo === Compiling proxy ===
cl.exe /c /nologo /O2 /GS- /Fovbox52_proxy.obj "%SRC%\vbox52_proxy.cpp"
if %errorlevel% neq 0 (echo CL FAILED & popd & endlocal & exit /b %errorlevel%)
cl.exe /c /nologo /O2 /GS- /Fospoof_thunks.obj "%SRC%\spoof_thunks.cpp"
if %errorlevel% neq 0 (echo CL FAILED & popd & endlocal & exit /b %errorlevel%)

echo === Linking ===
link.exe /nologo /dll /out:VBox52.dll /def:"%SRC%\vbox52.def" ^
  vbox52_proxy.obj vbox52_thunks.obj spoof_thunks.obj imachine_entries.obj ^
  ole32.lib oleaut32.lib psapi.lib
if %errorlevel% neq 0 (echo LINK FAILED & popd & endlocal & exit /b %errorlevel%)

echo === Done: %~dp0VBox52.dll ===
dumpbin /exports VBox52.dll | findstr /i "GetVBox DelVBox"
popd
endlocal
