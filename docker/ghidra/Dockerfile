# Disassembly / decompilation. Ghidra 12.x has NATIVE Xtensa and RISC-V, so no
# third-party processor module is needed - ESP32/S2/S3 (Xtensa LX6/LX7) and
# C3/C6/H2 (RISC-V) are all covered by stock Ghidra.
#
# Two modes:
#   headless - analyze an app image and export decompilation/symbols/strings
#   GUI      - interactive Ghidra over noVNC at http://localhost:6080
#
# Segments are mapped at their real load addresses (from the app image header,
# parsed by espfmt) so cross-references resolve, rather than importing a flat blob.
FROM eclipse-temurin:21-jdk

ENV DEBIAN_FRONTEND=noninteractive

ARG GHIDRA_VERSION=12.1.3
ARG GHIDRA_DATE=20260817
ARG GHIDRA_SHA256=93a5d11a9ad510622acaaf908c556a7b9b764d338e78a7567f3689bf5081fd54

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      curl unzip ca-certificates python3 \
      fontconfig libxrender1 libxtst6 libxi6 \
      tigervnc-standalone-server tigervnc-common \
      novnc websockify \
      fluxbox xterm \
 && rm -rf /var/lib/apt/lists/*

# Ghidra release, pinned + checksum-verified.
RUN cd /opt \
 && curl -sSL -o ghidra.zip \
      "https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${GHIDRA_VERSION}_build/ghidra_${GHIDRA_VERSION}_PUBLIC_${GHIDRA_DATE}.zip" \
 && echo "${GHIDRA_SHA256}  ghidra.zip" | sha256sum -c - \
 && unzip -q ghidra.zip \
 && rm ghidra.zip \
 && mv ghidra_${GHIDRA_VERSION}_PUBLIC /opt/ghidra

ENV GHIDRA_HOME=/opt/ghidra
ENV PATH="/opt/re/bin:${GHIDRA_HOME}/support:${PATH}"
ENV PYTHONPATH="/opt/re/lib"
ENV PYTHONUNBUFFERED=1
ENV WORK=/work

# Our segment-mapping + export helpers (bash + espfmt), and the Ghidra scripts
# (Jython) that run inside analyzeHeadless.
COPY scripts/container/lib    /opt/re/lib
COPY scripts/container/ghidra /opt/re/bin
RUN chmod +x /opt/re/bin/*.sh /opt/re/bin/*.py 2>/dev/null || true

# noVNC entry page at the root path.
RUN ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html || true

WORKDIR /work
LABEL org.opencontainers.image.title="esp32-re/ghidra"
LABEL org.opencontainers.image.description="Ghidra (Xtensa + RISC-V) for ESP32 badge RE"
CMD ["/bin/bash"]
