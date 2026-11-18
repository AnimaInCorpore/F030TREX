#!/usr/bin/env python3
"""Price one register-form MULS.L under an emulator timing profile.

Assembles tools/price_muls.s, runs it in an isolated directory and reports
what the profile charges for the multiply in the span walker's old prestep
sequence (OPTIMIZATION.md 3.14).  The 200 Hz counter measures emulated time.
This prices an emulator model; it is not a physical-Falcon timing.
"""

import argparse
import os
from pathlib import Path
import shutil
import struct
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("output", type=Path, help="new isolated output directory")
    ap.add_argument("--cpu-core", choices=("mmu", "cycle-exact"), default="mmu")
    ap.add_argument("--hatari", type=Path, default=ROOT.parent /
                    "F030Arcade/third_party/hatari/build/src/hatari")
    ap.add_argument("--tos", type=Path, default=ROOT.parent /
                    "F030Arcade/third_party/tos/tos402.img")
    args = ap.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    shutil.copy(ROOT / "tools/price_muls.s", out / "price_muls.s")
    subprocess.run([str(ROOT / "tools/vasm/vasmm68k_mot"), str(out / "price_muls.s"),
                    "-quiet", "-Felf", "-m68030", "-o", str(out / "price_muls.o")],
                   check=True)
    subprocess.run([str(ROOT / "tools/vlink/vlink"), str(out / "price_muls.o"),
                    "-tos-fastload", "-b", "ataritos", "-s", "-e", "start",
                    "-o", str(out / "MULPRICE.TOS")], check=True)
    mmu = args.cpu_core == "mmu"
    # The same two profiles tools/measure_frames.py pins.
    command = [str(args.hatari.resolve()), "--machine", "falcon", "--cpulevel", "3",
               "--cpuclock", "16", "--mmu", "true" if mmu else "false",
               "--cpu-exact", "true", "--compatible", "true",
               "--data-cache", "true", "--videl-contention",
               "false" if mmu else "true", "--patch-tos", "true",
               "--fast-boot", "true", "--tos", str(args.tos.resolve()),
               "--dsp", "emu", "--memsize", "4", "--ttram", "0",
               "--monitor", "rgb", "--frameskips", "4", "--sound", "off",
               "--benchmark", "--confirm-quit", "off", "--log-level", "fatal",
               "--alert-level", "fatal", "--harddrive", ".",
               "--auto", "C:\\MULPRICE.TOS", "--run-vbls", "3000"]
    result = out / "MULPRICE.RES"
    with (out / "hatari.log").open("w") as log:
        proc = subprocess.Popen(command, cwd=out, stdout=log, stderr=log,
                                env={**os.environ, "SDL_VIDEODRIVER": "dummy"})
        try:
            deadline = time.monotonic() + 240
            while time.monotonic() < deadline:
                if result.exists() and result.stat().st_size == 12:
                    break
                if proc.poll() is not None:
                    break
                time.sleep(0.05)
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
    if not result.exists() or result.stat().st_size != 12:
        raise SystemExit("no result; see " + str(out / "hatari.log"))
    without, with_mul, iterations = struct.unpack(">3I", result.read_bytes())

    def clocks(ticks):
        return ticks * 0.005 * 16.0e6 / iterations

    print("%s: %d iterations" % (args.cpu_core, iterations))
    print("  without MULS.L : %4d ticks, %6.2f clocks/iteration" % (without, clocks(without)))
    print("  with MULS.L    : %4d ticks, %6.2f clocks/iteration" % (with_mul, clocks(with_mul)))
    print("  one MULS.L     : %6.2f clocks" % clocks(with_mul - without))


if __name__ == "__main__":
    main()
