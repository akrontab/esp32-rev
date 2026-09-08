# Local GPU hash cracking. Runs on the RTX 3060 via Docker Desktop's WSL2
# NVIDIA passthrough - launched with --gpus all and NVIDIA_DRIVER_CAPABILITIES=all
# (see scripts/lib/Docker.ps1 Invoke-CrackContainer).
#
# Base image note: the -devel- image is required, not -runtime-. hashcat's CUDA
# backend needs libnvrtc, which only ships in devel. Verified: -runtime- falls
# back to a missing OpenCL ICD and finds no compute device at all.
FROM nvidia/cuda:12.4.1-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
# Ensure the container runtime mounts the full driver stack (CUDA + OpenCL),
# not just the default compute/utility subset.
ENV NVIDIA_DRIVER_CAPABILITIES=all
ENV NVIDIA_VISIBLE_DEVICES=all

ARG HASHCAT_VERSION=6.2.6

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      p7zip-full curl ca-certificates python3 python3-pip git \
 && rm -rf /var/lib/apt/lists/*

# hashcat release binary (portable; bundles its OpenCL kernels).
RUN cd /opt \
 && curl -sSL -o hashcat.7z "https://hashcat.net/files/hashcat-${HASHCAT_VERSION}.7z" \
 && 7z x -y hashcat.7z >/dev/null \
 && rm hashcat.7z \
 && ln -s /opt/hashcat-${HASHCAT_VERSION}/hashcat.bin /usr/local/bin/hashcat

# name-that-hash / hashid for identifying unknown hashes -> hashcat modes.
RUN pip3 install --no-cache-dir name-that-hash hashid \
 && python3 -c "import name_that_hash" 2>/dev/null || true

# Baked-in wordlist + rules so the image is self-contained and works offline at
# a venue. rockyou is the universal first pass; OneRuleToRuleThemAll is the
# single best general-purpose rule set. Bigger lists are mounted from the
# gitignored wordlists/ dir instead (see fetch-wordlists.sh).
RUN mkdir -p /opt/wordlists /opt/rules \
 && curl -sSL -o /opt/wordlists/rockyou.txt \
      "https://github.com/brannondorsey/naive-hashcat/releases/download/data/rockyou.txt" \
 && curl -sSL -o /opt/rules/OneRuleToRuleThemAll.rule \
      "https://raw.githubusercontent.com/NotSoSecure/password_cracking_rules/master/OneRuleToRuleThemAll.rule" \
 && wc -l /opt/wordlists/rockyou.txt /opt/rules/OneRuleToRuleThemAll.rule

# hashcat ships its own high-value rules (best64, dive, ...); expose them too.
ENV HASHCAT_RULES_DIR=/opt/hashcat-${HASHCAT_VERSION}/rules

COPY scripts/container/lib     /opt/re/lib
COPY scripts/container/hashcat /opt/re/bin
RUN chmod +x /opt/re/bin/* 2>/dev/null || true

ENV PATH="/opt/re/bin:${PATH}"
ENV PYTHONPATH="/opt/re/lib"
ENV PYTHONUNBUFFERED=1
ENV WORK=/work

WORKDIR /work
LABEL org.opencontainers.image.title="esp32-re/hashcat"
LABEL org.opencontainers.image.description="Local GPU hash cracking for ESP32 badge RE"
CMD ["/bin/bash"]
