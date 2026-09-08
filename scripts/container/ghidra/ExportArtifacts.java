// Ghidra postScript: after auto-analysis, export the results as plain files so
// they land in the workspace and can be grepped/diffed without opening the GUI:
//   decompiled.c        every function's decompiled C
//   functions.txt       address, name, size of each function
//   symbols.txt         the symbol table
//   strings-ghidra.txt  defined strings with their addresses
//
// Java so it runs on any Ghidra without a Python bridge.
// Arg: output directory (reports/ghidra).
// @category ESP32
import java.io.File;
import java.io.PrintWriter;
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;

public class ExportArtifacts extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        String outDir = args.length > 0 ? args[0] : ".";
        new File(outDir).mkdirs();

        int funcs = exportDecompilation(outDir);
        exportFunctionList(outDir);
        int syms = exportSymbols(outDir);
        int strs = exportStrings(outDir);

        println(String.format("ExportArtifacts: %d functions decompiled, %d symbols, %d strings",
            funcs, syms, strs));
    }

    private int exportDecompilation(String outDir) throws Exception {
        DecompInterface di = new DecompInterface();
        di.openProgram(currentProgram);
        PrintWriter w = new PrintWriter(new File(outDir, "decompiled.c"));
        w.println("// Decompiled by Ghidra headless - " + currentProgram.getName());
        w.println("// entry: " + currentProgram.getImageBase());
        w.println();
        int n = 0;
        FunctionIterator it = currentProgram.getFunctionManager().getFunctions(true);
        while (it.hasNext() && !monitor.isCancelled()) {
            Function fn = it.next();
            try {
                DecompileResults r = di.decompileFunction(fn, 60, monitor);
                if (r != null && r.decompileCompleted()) {
                    w.println(r.getDecompiledFunction().getC());
                    w.println();
                    n++;
                }
            } catch (Exception e) {
                w.println("// " + fn.getName() + " @ " + fn.getEntryPoint() + " : decompile failed");
            }
        }
        w.close();
        di.dispose();
        return n;
    }

    private void exportFunctionList(String outDir) throws Exception {
        PrintWriter w = new PrintWriter(new File(outDir, "functions.txt"));
        FunctionIterator it = currentProgram.getFunctionManager().getFunctions(true);
        while (it.hasNext()) {
            Function fn = it.next();
            w.println(String.format("%s  %-40s  %d bytes",
                fn.getEntryPoint(), fn.getName(), fn.getBody().getNumAddresses()));
        }
        w.close();
    }

    private int exportSymbols(String outDir) throws Exception {
        PrintWriter w = new PrintWriter(new File(outDir, "symbols.txt"));
        int n = 0;
        SymbolIterator it = currentProgram.getSymbolTable().getAllSymbols(true);
        while (it.hasNext()) {
            Symbol s = it.next();
            w.println(s.getAddress() + "\t" + s.getName() + "\t" + s.getSymbolType());
            n++;
        }
        w.close();
        return n;
    }

    private int exportStrings(String outDir) throws Exception {
        // Iterate all defined data and keep those whose value is a String.
        // Version-stable across Ghidra releases, unlike DefinedDataIterator.
        PrintWriter w = new PrintWriter(new File(outDir, "strings-ghidra.txt"));
        int n = 0;
        DataIterator it = currentProgram.getListing().getDefinedData(true);
        while (it.hasNext() && !monitor.isCancelled()) {
            Data d = it.next();
            Object v = d.getValue();
            if (v instanceof String) {
                w.println(d.getAddress() + "\t" + ((String) v).replace("\n", "\\n"));
                n++;
            }
        }
        w.close();
        return n;
    }
}
