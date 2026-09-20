#!/usr/bin/env bash
# Start Ghidra's interactive GUI, reachable in a browser over noVNC.
#
# The container is run with -p 6080:6080 by the control plane; open
# http://localhost:6080/vnc.html and click Connect. Use this for the deep dive
# after headless analysis has pointed you at the interesting functions.
#
# The workspace is at /work; import reports/ghidra/seg_*.bin, or open the app
# image directly and set the language to Xtensa:LE:32:default (or
# RISCV:LE:32:default for C3/C6).

set -e
export DISPLAY=:1
GEO="${GEO:-1600x900}"

echo "[*] Starting virtual display + VNC on :1 ($GEO)"
# No VNC password, no TLS: reachable only through noVNC (websockify), which runs
# in this same container. VNC binds to localhost *inside* the container
# (-localhost yes); websockify connects to it locally and only :6080 is
# published, to 127.0.0.1, by the control plane. -localhost yes is also required
# by TigerVNC >= 1.15, which refuses -SecurityTypes None on a non-local bind.
vncserver -kill :1 >/dev/null 2>&1 || true
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true
vncserver :1 -geometry "$GEO" -depth 24 -SecurityTypes None -localhost yes >/tmp/vnc.log 2>&1

echo "[*] Starting window manager"
DISPLAY=:1 fluxbox >/tmp/fluxbox.log 2>&1 &

echo "[*] Starting noVNC on :6080"
websockify --web=/usr/share/novnc 6080 localhost:5901 >/tmp/novnc.log 2>&1 &
WS_PID=$!
sleep 1

echo
echo "==============================================================="
echo "  Ghidra GUI: open  http://localhost:6080/vnc.html  and Connect"
echo "  Workspace is /work.  Ctrl-C here to stop."
echo "==============================================================="
echo

# ghidraRun is a launcher that forks the JVM and returns, so we can't wait on
# it - the container would exit while Ghidra is still running. Keep the
# container alive on the noVNC bridge instead (that's what serves the GUI);
# Ctrl-C tears it all down.
DISPLAY=:1 "$GHIDRA_HOME/ghidraRun" >/tmp/ghidra.log 2>&1 &
trap 'echo "[*] stopping"; vncserver -kill :1 >/dev/null 2>&1 || true; kill $WS_PID 2>/dev/null || true' INT TERM
wait $WS_PID
