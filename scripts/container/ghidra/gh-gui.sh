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
# No VNC password, no TLS: the port is only exposed to localhost by the control
# plane, and the container is disposable. Do not publish 6080 to a public iface.
vncserver -kill :1 >/dev/null 2>&1 || true
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true
vncserver :1 -geometry "$GEO" -depth 24 -SecurityTypes None -localhost no >/tmp/vnc.log 2>&1

echo "[*] Starting window manager"
DISPLAY=:1 fluxbox >/tmp/fluxbox.log 2>&1 &

echo "[*] Starting noVNC on :6080"
websockify --web=/usr/share/novnc 6080 localhost:5901 >/tmp/novnc.log 2>&1 &
sleep 1

echo
echo "==============================================================="
echo "  Ghidra GUI: open  http://localhost:6080/vnc.html  and Connect"
echo "  Workspace is /work.  Ctrl-C here to stop."
echo "==============================================================="
echo

DISPLAY=:1 "$GHIDRA_HOME/ghidraRun" >/tmp/ghidra.log 2>&1 &
GH_PID=$!

# Keep the container alive while the GUI runs; Ctrl-C tears it all down.
trap 'echo "[*] stopping"; vncserver -kill :1 >/dev/null 2>&1 || true; kill $GH_PID 2>/dev/null || true' INT TERM
wait $GH_PID
