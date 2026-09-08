# Hardware-facing image: everything that talks to the badge over serial.
# Deliberately minimal - this is the only image that gets a --device passed in.
FROM python:3.12-slim

ARG ESPTOOL_VERSION=5.4.0

# procps is only here so the serial monitor can be inspected/killed cleanly.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates procps \
 && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
      "esptool==${ESPTOOL_VERSION}" \
      "pyserial>=3.5"

COPY scripts/container/lib     /opt/re/lib
COPY scripts/container/esptool /opt/re/bin
RUN chmod +x /opt/re/bin/* /opt/re/lib/*.py 2>/dev/null || true

ENV PATH="/opt/re/bin:/opt/re/lib:${PATH}"
ENV PYTHONPATH="/opt/re/lib"
ENV PYTHONUNBUFFERED=1
ENV WORK=/work

WORKDIR /work
LABEL org.opencontainers.image.title="esp32-re/esptool"
LABEL org.opencontainers.image.description="Serial acquisition tools for ESP32 badge RE"
CMD ["/bin/bash"]
