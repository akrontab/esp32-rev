# Ghidra image (phase 2 — not built yet)

Intentionally empty. Menu option `[2] -> 4` reports that no Dockerfile exists
here rather than pretending otherwise.

The design is already decided — headless analysis for repeatable per-dump runs
plus an optional noVNC GUI on `localhost:6080` — and the implementation notes,
including the memory-mapping detail that makes ESP32 disassembly useful rather
than noise, are in [../../docs/roadmap.md](../../docs/roadmap.md#ghidra-image--disassembly).

Build it when static analysis stops paying, i.e. when the flag is computed at
runtime rather than stored.
