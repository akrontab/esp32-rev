// Ghidra preScript: map the ESP32 app image's non-primary segments as memory
// blocks at their real load addresses, so cross-references between code (IROM/
// IRAM) and constants/strings (DROM/DRAM) resolve during analysis.
//
// analyzeHeadless imports the primary (entry-bearing) segment via the Raw
// Binary loader; this adds the rest from the per-segment files gh-prep wrote.
// Written in Java (not Python) so it runs on any Ghidra without a script bridge.
//
// Arg: absolute path to segments.tsv  (index, base-hex, length, exec, file, primary)
// @category ESP32
import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.FileInputStream;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.mem.MemoryBlock;

public class AddSegments extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 1) {
            println("AddSegments: no segments.tsv path given");
            return;
        }
        File tsv = new File(args[0]);
        File dir = tsv.getParentFile();

        BufferedReader br = new BufferedReader(new FileReader(tsv));
        String line;
        while ((line = br.readLine()) != null) {
            if (line.trim().isEmpty()) continue;
            String[] f = line.split("\t");
            int index = Integer.parseInt(f[0]);
            long base = Long.parseLong(f[1], 16);
            long length = Long.parseLong(f[2]);
            boolean exec = f[3].equals("1");
            String fname = f[4];
            boolean primary = f[5].equals("1");
            if (primary) continue;   // already loaded by the importer

            File segFile = new File(dir, fname);
            Address addr = toAddr(base);
            String name = "seg" + index + "_" + Long.toHexString(base);
            try {
                MemoryBlock blk = currentProgram.getMemory().createInitializedBlock(
                    name, addr, new FileInputStream(segFile), length, monitor, false);
                blk.setRead(true);
                blk.setWrite(!exec);
                blk.setExecute(exec);
                println(String.format("AddSegments: mapped %s at 0x%08x (%d bytes, %s)",
                    name, base, length, exec ? "code" : "data"));
            } catch (Exception e) {
                println("AddSegments: could not map " + name + ": " + e.getMessage());
            }
        }
        br.close();
    }
}
