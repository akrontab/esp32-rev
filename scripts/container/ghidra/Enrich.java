// Ghidra postScript: enrich the analysis before it is exported, then write the
// cross-reference views that turn a wall of FUN_* into something navigable.
//
//   1. ROM symbols - if rom-symbols.tsv is present (from rom-syms.py), label
//      each ROM address with its real name, so calls into the mask ROM read as
//      ets_printf / memcpy / esp_rom_crc32_le rather than FUN_40xxxxxx. What is
//      left unnamed is then the app's own code.
//   2. xref-strings.txt - for every defined string, which functions reference
//      it. Answers "where is this string used?" precisely (real xrefs, not grep).
//   3. func-strings.txt - the inverse: for each function, the string literals it
//      touches. A function's strings are its log tags / prompts / messages, so
//      this reads as a rough, free labelling of what each function is about.
//
// Runs before ExportArtifacts so the ROM names land in decompiled.c too.
// Java so it runs on any Ghidra without a script bridge.
// Arg: output directory (reports/ghidra).
// @category ESP32
import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.model.symbol.SourceType;

public class Enrich extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        String outDir = args.length > 0 ? args[0] : ".";
        new File(outDir).mkdirs();

        int romApplied = applyRomSymbols(outDir);
        int[] xr = writeXrefs(outDir);

        println(String.format(
            "Enrich: %d ROM symbols applied, %d strings cross-referenced, %d functions labelled by strings",
            romApplied, xr[0], xr[1]));
    }

    /** Label each address in rom-symbols.tsv (address<TAB>name) with its name. */
    private int applyRomSymbols(String outDir) {
        File tsv = new File(outDir, "rom-symbols.tsv");
        if (!tsv.isFile()) {
            println("Enrich: no rom-symbols.tsv (run rom-syms.py to enable ROM naming) - skipping");
            return 0;
        }
        int applied = 0;
        try (BufferedReader br = new BufferedReader(new FileReader(tsv))) {
            String line;
            while ((line = br.readLine()) != null) {
                line = line.trim();
                if (line.isEmpty() || line.startsWith("#")) continue;
                String[] f = line.split("\\t");
                if (f.length < 2) continue;
                Address a;
                try {
                    a = toAddr(Long.parseLong(f[0], 16));
                } catch (NumberFormatException e) {
                    continue;
                }
                // Only label addresses that actually landed in this program's
                // memory - the ROM overlaps the mapped ranges on these parts.
                if (a == null || !currentProgram.getMemory().contains(a)) continue;
                try {
                    currentProgram.getSymbolTable().createLabel(a, f[1], SourceType.IMPORTED);
                    applied++;
                } catch (Exception e) {
                    // name clash or bad address - skip quietly, keep going
                }
            }
        } catch (Exception e) {
            println("Enrich: could not read rom-symbols.tsv: " + e.getMessage());
        }
        return applied;
    }

    /** Write string->functions and function->strings cross-reference reports. */
    private int[] writeXrefs(String outDir) throws Exception {
        FunctionManager fm = currentProgram.getFunctionManager();
        // Preserve discovery order so the reports read stably.
        Map<String, List<String>> funcToStrings = new LinkedHashMap<>();
        int strings = 0;

        PrintWriter ws = new PrintWriter(new File(outDir, "xref-strings.txt"));
        ws.println("# string  ->  functions that reference it");
        DataIterator it = currentProgram.getListing().getDefinedData(true);
        while (it.hasNext() && !monitor.isCancelled()) {
            Data d = it.next();
            Object v = d.getValue();
            if (!(v instanceof String)) continue;
            String text = ((String) v).replace("\n", "\\n");
            if (text.length() < 3) continue;              // skip trivial fragments
            strings++;

            List<String> users = new ArrayList<>();
            ReferenceIterator refs = currentProgram.getReferenceManager()
                    .getReferencesTo(d.getAddress());
            while (refs.hasNext()) {
                Reference r = refs.next();
                Function f = fm.getFunctionContaining(r.getFromAddress());
                String fn = (f != null) ? f.getName() : ("@" + r.getFromAddress());
                if (!users.contains(fn)) users.add(fn);
                funcToStrings.computeIfAbsent(fn, k -> new ArrayList<>());
                List<String> ss = funcToStrings.get(fn);
                if (!ss.contains(text)) ss.add(text);
            }
            if (!users.isEmpty()) {
                ws.println(String.format("%s\t\"%s\"", d.getAddress(), text));
                ws.println("    used by: " + String.join(", ", users));
            }
        }
        ws.close();

        PrintWriter wf = new PrintWriter(new File(outDir, "func-strings.txt"));
        wf.println("# function  ->  string literals it references (its tags / messages)");
        for (Map.Entry<String, List<String>> e : funcToStrings.entrySet()) {
            wf.println(e.getKey());
            for (String s : e.getValue()) {
                wf.println("    \"" + s + "\"");
            }
        }
        wf.close();

        return new int[] { strings, funcToStrings.size() };
    }
}
