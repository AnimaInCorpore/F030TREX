#!/usr/bin/env python3
"""Time short 68030 loops under an emulator timing profile.

Assembles tools/price_loops.s, runs it in an isolated directory and prints
the clocks per iteration of each loop, from the 200 Hz counter (emulated
time).  Compare with the MC68030 manual's figures from tools/m68030_cc.py
(OPTIMIZATION.md 3.19).  `--env NAME=VALUE` passes an environment variable
to Hatari, e.g. HATARI_CPU030_TIMING=manual.  These price an emulator
model; they are not physical-Falcon timings.
"""

import argparse
import os
from pathlib import Path
import shutil
import struct
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
NAMES = ["dbra alone", "move.l #imm + muls.l", "move.l #imm (control)",
         "3 moves + lsr.w #8", "stream loop (indexed)", "delta loop (adda.w)",
         "record loop", "record loop, adds first", "flat store"]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("output", type=Path, help="new isolated output directory")
    ap.add_argument("--cpu-core", choices=("mmu", "cycle-exact"), default="cycle-exact")
    ap.add_argument("--videl-contention", choices=("on", "off"), default=None)
    ap.add_argument("--memsize", choices=("4", "14"), default="14")
    ap.add_argument("--env", action="append", default=[], metavar="NAME=VALUE")
    ap.add_argument("--hatari", type=Path, default=ROOT.parent /
                    "F030Arcade/third_party/hatari/build/src/hatari")
    ap.add_argument("--tos", type=Path, default=ROOT.parent /
                    "F030Arcade/third_party/tos/tos402.img")
    args = ap.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    shutil.copy(ROOT / "tools/price_loops.s", out / "price_loops.s")
    subprocess.run([str(ROOT / "tools/vasm/vasmm68k_mot"), str(out / "price_loops.s"),
                    "-quiet", "-Felf", "-m68030", "-o", str(out / "price_loops.o")],
                   check=True)
    subprocess.run([str(ROOT / "tools/vlink/vlink"), str(out / "price_loops.o"),
                    "-tos-fastload", "-b", "ataritos", "-s", "-e", "start",
                    "-o", str(out / "PRICELPS.TOS")], check=True)
    mmu = args.cpu_core == "mmu"
    contention = args.videl_contention or ("off" if mmu else "on")
    command = [str(args.hatari.resolve()), "--machine", "falcon", "--cpulevel", "3",
               "--cpuclock", "16", "--mmu", "true" if mmu else "false",
               "--cpu-exact", "true", "--compatible", "true",
               "--data-cache", "true", "--videl-contention",
               "true" if contention == "on" else "false", "--patch-tos", "true",
               "--fast-boot", "true", "--tos", str(args.tos.resolve()),
               "--dsp", "emu", "--memsize", args.memsize, "--ttram", "0",
               "--monitor", "rgb", "--frameskips", "4", "--sound", "off",
               "--benchmark", "--confirm-quit", "off", "--log-level", "fatal",
               "--alert-level", "fatal", "--harddrive", ".",
               "--auto", "C:\\PRICELPS.TOS", "--run-vbls", "20000"]
    env = {**os.environ, "SDL_VIDEODRIVER": "dummy"}
    for item in args.env:
        name, _, value = item.partition("=")
        env[name] = value
    result = out / "PRICELPS.RES"
    size = 8 + 4 * len(NAMES)
    with (out / "hatari.log").open("w") as log:
        proc = subprocess.Popen(command, cwd=out, stdout=log, stderr=log, env=env)
        try:
            deadline = time.monotonic() + 600
            while time.monotonic() < deadline:
                if result.exists() and result.stat().st_size == size:
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
    if not result.exists() or result.stat().st_size != size:
        raise SystemExit("no result; see " + str(out / "hatari.log"))
    values = struct.unpack(">%dI" % (size // 4), result.read_bytes())
    count, iterations, ticks = values[0], values[1], values[2:]
    assert count == len(NAMES)
    print("%s, Videl contention %s, %s: %d iterations per loop"
          % (args.cpu_core, contention, " ".join(args.env) or "default timing", iterations))
    for name, t in zip(NAMES, ticks):
        print("  %-26s %5d ticks  %6.2f clocks/iteration" % (name, t, t * 0.005 * 16.0e6 / iterations))


if __name__ == "__main__":
    main()
