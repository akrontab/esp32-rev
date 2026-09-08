# Ghidra image

Built. Ghidra 12.1.3 with **native Xtensa + RISC-V**, plus a noVNC GUI stack.

- Headless analysis exports decompilation/symbols/strings into the workspace.
- GUI over noVNC at http://localhost:6080/vnc.html.

Driven from the control plane (menu `[33]` headless, `[34]` GUI) and documented
in [../../docs/ghidra.md](../../docs/ghidra.md). Processor support is stock —
no third-party module — because Ghidra 12 ships Xtensa natively.
