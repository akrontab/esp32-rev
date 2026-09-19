# esp32-re/arduino

A reference-build image for Ghidra **name recovery**. It carries `arduino-cli`;
the `arduino-esp32` core is installed at run time (pinned to whatever version
matches the badge's SDK), and `arduino-ref.sh` compiles a **symbolised**
reference ELF from the same toolchain the badge was built with.

Ghidra can then match that reference against the stripped dump (FunctionID or
BinDiff) and name the SDK/Arduino/libc functions, leaving the badge's own code
as what remains unnamed. See [docs/name-recovery.md](../../docs/name-recovery.md).

Driven from the control plane: **`[37]` Build SDK reference**. Build the image
from the menu (`[2] -> 6`) or `Build-Image -Name arduino`.

- Read-only toward the badge: it only downloads public packages and compiles
  offline. It needs network (unlike the badge-facing images).
- The core download is cached in a Docker volume (`esp32-re-arduino-cache`), so
  only the first build of a given version pays the download cost.
