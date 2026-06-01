# Ghidra Python script to analyze VBox52.dll
# Run with: analyzeHeadless <project> -import VBox52.dll -postScript analyze_vbox52.py

import os
import jarray

OUTPUT_DIR = r"F:\各种项目\逆向ensp\analysis\output"

def log(msg):
    print(msg)
    with open(os.path.join(OUTPUT_DIR, "analysis_log.txt"), "a") as f:
        f.write(msg + "\n")

def get_function_info(func):
    """Get basic info about a function"""
    body = func.getBody()
    return {
        "name": func.getName(),
        "address": str(func.getEntryPoint()),
        "size": body.getNumAddresses(),
        "calling_convention": str(func.getCallingConvention())
    }

# Create output dir
if not os.path.exists(OUTPUT_DIR):
    os.makedirs(OUTPUT_DIR)

log("=" * 60)
log("VBox52.dll Analysis Started")
log("=" * 60)

# Get current program
program = currentProgram
if program is None:
    log("ERROR: No program loaded!")
    exit(1)

log("Program: %s" % program.getName())
log("Language: %s" % program.getLanguageID())
log("Compiler: %s" % program.getCompilerSpec().getCompilerSpecID())

# Wait for analysis to complete
log("\nWaiting for auto-analysis to complete...")
import time
time.sleep(60)  # Give Ghidra time to finish analysis
log("Continuing after analysis delay")

# 1. List all exported functions
log("\n--- Exported Functions ---")
symbol_table = program.getSymbolTable()
external_refs = []
for symbol in symbol_table.getSymbolIterator():
    if symbol.isExternal():
        external_refs.append(symbol)
        continue
    if symbol.getSymbolType().toString() == "Function":
        log("  %s @ %s" % (symbol.getName(), str(symbol.getAddress())))
    elif symbol.getSymbolType().toString() == "Label":
        log("  Label: %s @ %s" % (symbol.getName(), str(symbol.getAddress())))

# 2. Get the exported functions (GetVBoxInstance, DelVBoxInstance)
log("\n--- Export Entry Points ---")
fm = program.getFunctionManager()
ext_funcs = fm.getExternalFunctions()
for func in ext_funcs:
    log("  External: %s" % func.getName())

# 3. Find all calls to CoCreateInstance
log("\n--- CoCreateInstance References ---")
from ghidra.app.util import XReferenceUtils
from ghidra.program.model.symbol import RefType
from ghidra.program.model.lang import OperandType

# Get the CoCreateInstance external location
import ghidra.program.model.address.AddressSetView as ASV

listing = currentProgram.getListing()
co_create_refs = []

# Search for the import thunk
for sym in symbol_table.getSymbolIterator():
    name = sym.getName()
    if "CoCreate" in name or "CoCreateInstance" in name:
        log("  Found symbol: %s @ %s" % (name, str(sym.getAddress())))
        # Find all references to it
        ref_mgr = currentProgram.getReferenceManager()
        refs = ref_mgr.getReferencesTo(sym.getAddress())
        for ref in refs:
            caller = ref.getFromAddress()
            caller_func = fm.getFunctionContaining(caller)
            if caller_func:
                log("    Called from: %s @ %s" % (caller_func.getName(), str(caller)))
                co_create_refs.append((caller_func, caller))

# 4. Decompile the CoCreateInstance calling functions
log("\n--- Decompiled CoCreateInstance callers ---")
if co_create_refs:
    from ghidra.app.decompiler import DecompInterface
    decomp = DecompInterface()
    decomp.openProgram(currentProgram)

    for func, addr in co_create_refs:
        log("\nFunction: %s @ %s" % (func.getName(), str(func.getEntryPoint())))
        decomp_result = decomp.decompileFunction(func, 60, monitor)
        if decomp_result and decomp_result.getDecompiledFunction():
            code = decomp_result.getDecompiledFunction().getC()
            log(code)
        else:
            log("  Decompilation failed")
else:
    log("  No CoCreateInstance references found via symbols")

# 5. Dump .rdata section for GUID analysis
log("\n--- .rdata section GUIDs ---")
memory = currentProgram.getMemory()
for block in memory.getBlocks():
    name = block.getName()
    if '.rdata' in name or '.data' in name:
        log("Block: %s @ %s size: %s" % (name, str(block.getStart()),
            str(block.getSize())))

        # Try to find GUID patterns in the block
        from ghidra.program.model.data import GUIDDataType
        try:
            data_mgr = currentProgram.getListing()
            data = data_mgr.getDefinedData(block.getStart(), True)
            count = 0
            while data and count < 100:
                dt = data.getDataType()
                if "GUID" in str(dt) or "guid" in str(dt).lower() or "UUID" in str(dt):
                    log("  GUID @ %s: %s" % (str(data.getAddress()), str(data.getValue())))
                    count += 1
                data = data_mgr.getDefinedDataAfter(data.getAddress())
        except Exception as e:
            log("  GUID scan error: %s" % str(e))

# 6. List all potential vtable references (IVBoxInterface)
log("\n--- VTable / Class Structure ---")
try:
    from ghidra.program.model.data import StructureDataType
    from ghidra.program.model.data import PointerDataType
except:
    pass

# List all classes found via RTTI
from ghidra.program.database import ProgramDB
try:
    rtti_util = ghidra.plugins.framework.RTTI4Util(currentProgram)
    classes = rtti_util.getClassRTTI()
    log("Found %d RTTI classes" % len(classes))
    for cls in classes[:20]:
        log("  %s" % str(cls))
except Exception as e:
    log("RTTI scan error: %s" % str(e))

log("\n" + "=" * 60)
log("Analysis Complete")
log("=" * 60)
