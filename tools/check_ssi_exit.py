#!/usr/bin/env python3
"""Exercise real keypress shutdown through Hatari's documented control socket.

Diagnostic mode requires the SSI sidecar to show live ownership and then
release. Release mode requires a live Crossbar route and no application dumps.
The raw post-exit sound controls must be idle in both modes. This is an
emulator ownership/exit gate, not a physical cache or performance measurement.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('binary', type=Path)
    p.add_argument('dsp', type=Path)
    p.add_argument('output', type=Path)
    p.add_argument('--release', action='store_true')
    a = p.parse_args()
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    (out / 'RUN.TOS').write_bytes(a.binary.read_bytes())
    (out / 'TREXPIPE.LOD').write_bytes(a.dsp.read_bytes())
    with tempfile.TemporaryDirectory(prefix='trex-ssi-') as tmp:
        endpoint = str(Path(tmp) / 'control')
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(endpoint)
        server.listen(1)
        server.settimeout(15)
        cmd = [str(ROOT.parent / 'F030Arcade/third_party/hatari/build/src/hatari'),
               '--machine', 'falcon', '--cpulevel', '3', '--cpuclock', '16',
               '--mmu', 'false', '--cpu-exact', 'true', '--compatible', 'true',
               '--data-cache', 'true', '--videl-contention', 'true', '--dsp', 'emu',
               '--tos', str(ROOT.parent / 'F030Arcade/third_party/tos/tos402.img'),
               '--memsize', '4', '--ttram', '0', '--monitor', 'rgb',
               '--sound', 'off', '--benchmark', '--fast-boot', 'true',
               '--patch-tos', 'true', '--confirm-quit', 'off', '--harddrive', '.',
               '--auto', 'C:\\RUN.TOS', '--control-socket', endpoint,
               '--log-level', 'fatal', '--alert-level', 'fatal']
        with (out / 'hatari.log').open('w') as log:
            proc = subprocess.Popen(cmd, cwd=out, stdout=log, stderr=log,
                                    env={**os.environ, 'SDL_VIDEODRIVER': 'dummy'})
            control = None
            try:
                control, _ = server.accept()
                control.sendall(b'hatari-debug savebin before.bin $ff8900 #64\n')
                deadline = time.monotonic() + 90
                while time.monotonic() < deadline:
                    if a.release:
                        control.sendall(b'hatari-debug savebin live.bin $ff8900 #64\n')
                        time.sleep(0.1)
                        b = (out / 'live.bin').read_bytes() if (out / 'live.bin').exists() else b''
                        ready = len(b) == 64 and b[0x30:0x34] == b'\x00\xc0\x00\x02'
                    else:
                        b = (out / 'render_stats.res').read_bytes() if (out / 'render_stats.res').exists() else b''
                        ready = len(b) == 92 and struct.unpack_from('>I', b)[0] >= 8
                    if ready:
                        break
                    if proc.poll() is not None:
                        raise RuntimeError('Hatari exited during startup')
                    time.sleep(0.01)
                else:
                    raise RuntimeError('SSI renderer never reached live state')
                control.sendall(b'hatari-event keypress x\n')
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    control.sendall(b'hatari-debug savebin after.bin $ff8900 #64\n')
                    time.sleep(0.1)
                    after = (out / 'after.bin').read_bytes() if (out / 'after.bin').exists() else b''
                    if len(after) == 64 and after[1] & 0x11 == 0 and after[0x30:0x34] != b'\x00\xc0\x00\x02':
                        break
                else:
                    raise RuntimeError('keypress did not release the owned DMA/Crossbar')
                before = (out / 'before.bin').read_bytes()
                # DMA count pointers are read-only and are not an ownership state.
                restored = {i: (before[i], after[i]) for i in (0, 1, 0x20, 0x21,
                            0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36,
                            0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d)}
                if a.release:
                    assert not list(out.glob('*.res')), 'release wrote application dumps'
                else:
                    status = struct.unpack('>12I', (out / 'ssi_pipe.res').read_bytes())
                    assert status[0] == 0 and status[1] == 0 and status[9] == 0
                result = {'command': cmd, 'release': a.release,
                          'clean_exit': True, 'idle_control': after[1],
                          'boot_vs_restored_registers': restored,
                          'no_release_dumps': a.release}
                (out / 'exit.json').write_text(json.dumps(result, indent=2) + '\n')
                print('Clean keypress exit; idle DMA/Crossbar; release dumps:', list(out.glob('*.res')) if a.release else 'diagnostic sidecars')
            finally:
                if control:
                    control.close()
                server.close()
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()


if __name__ == '__main__':
    main()
