# Reference-build image for Ghidra name recovery.
#
# A stripped badge image is ~95% ESP-IDF / Arduino-core / libc code compiled
# from public source. If we rebuild that SAME toolchain's output *with* symbols,
# Ghidra's FunctionID / BinDiff can name those functions in the dump - leaving
# the badge's own code as what's left unnamed. This image is just arduino-cli;
# the esp32 core is installed at RUN time, pinned to whatever version matches
# the badge's SDK (so one image serves any version, new or old).
#
# Nothing here touches the badge - it only downloads public packages and
# compiles a reference sketch offline.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ARG ARDUINO_CLI_VERSION=1.1.1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git xz-utils \
      python3 python3-pip python3-serial \
 && rm -rf /var/lib/apt/lists/*

# arduino-cli, pinned. The install script honours BINDIR and a version arg.
RUN curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh \
      | BINDIR=/usr/local/bin sh -s ${ARDUINO_CLI_VERSION} \
 && arduino-cli version

# The esp32 boards live behind Espressif's package index; the core itself is
# installed at run time (cached via a mounted volume) so the version is a knob.
ENV ARDUINO_BOARD_MANAGER_ADDITIONAL_URLS=https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json
ENV ARDUINO_DIRECTORIES_DATA=/root/.arduino15
ENV PATH="/opt/re/bin:${PATH}"

COPY scripts/container/arduino /opt/re/bin
RUN chmod +x /opt/re/bin/*.sh 2>/dev/null || true

WORKDIR /work
LABEL org.opencontainers.image.title="esp32-re/arduino"
LABEL org.opencontainers.image.description="arduino-cli reference builder for Ghidra name recovery"
CMD ["/bin/bash"]
