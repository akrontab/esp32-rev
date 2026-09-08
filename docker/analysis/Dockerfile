# Offline analysis image: never gets a serial device, only the workspace.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# No radare2 here: it has no installation candidate in bookworm, and real
# disassembly belongs in the Ghidra image which understands both Xtensa and
# RISC-V. riscv64 objdump is cheap and covers quick looks at C3/C6 code.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 python3-pip python3-venv \
      binwalk \
      binutils \
      file bsdmainutils xxd less \
      p7zip-full unzip gzip xz-utils zstd \
      squashfs-tools \
      jq ripgrep \
      binutils-riscv64-linux-gnu \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# littlefs-python gives us real LittleFS extraction; the ESP-specific formats
# (image headers, partition table, NVS, SPIFFS) are parsed by our own code in
# /opt/re/lib so analysis never needs the network.
RUN pip3 install --no-cache-dir --break-system-packages \
      "littlefs-python==0.19.0" \
      "pyelftools>=0.31" \
 && python3 -c "import littlefs, elftools; print('fs libs ok')"

COPY scripts/container/lib      /opt/re/lib
COPY scripts/container/analysis /opt/re/bin
RUN chmod +x /opt/re/bin/* /opt/re/lib/*.py 2>/dev/null || true

ENV PATH="/opt/re/bin:/opt/re/lib:${PATH}"
ENV PYTHONPATH="/opt/re/lib"
ENV PYTHONUNBUFFERED=1
ENV WORK=/work

WORKDIR /work
LABEL org.opencontainers.image.title="esp32-re/analysis"
LABEL org.opencontainers.image.description="Offline firmware carving and analysis for ESP32 badge RE"
CMD ["/bin/bash"]
