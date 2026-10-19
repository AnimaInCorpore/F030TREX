#!/usr/bin/env python3
"""Run the actual M68030 span walker on synthetic edge cases in Hatari.

Extracts the production routine, links a small TOS harness and compares every
framebuffer byte, guard and counter against independent fixture expectations.
This is a correctness check, never a throughput benchmark.
"""

import argparse
import os
from pathlib import Path
import re
import struct
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
W, H, STRIDE = 240, 224, 256
BACKGROUND = 0x0842


def fixture(name, kind="opaque", x=0, right=W, y=0, rows=H,
            halves=None, u=0, du=256, dv=0, fraction=0, level=0):
    image = [BACKGROUND] * (STRIDE * H)
    count = 0
    for sy in range(max(0, y), min(H, y + rows)):
        for sx in range(max(0, x + bool(fraction)), min(W, right)):
            distance = (sx - x) * 4096 - fraction
            tu = ((u + distance * du // 4096) >> 8) & 255
            tv = ((distance * dv // 4096) >> 8) & 255
            index = (tu ^ tv) & 1
            if kind in ("transparent", "semi") and not index:
                continue
            colour = 0x1234 if kind == "flat" else (0x5678 if index else 0x1234)
            if kind == "semi":
                # Palette index 1 has STP set: per-channel floor average.
                colour = sum((((0xF800 >> shift) & 31)
                              + ((BACKGROUND >> shift) & 31)) // 2 << shift
                             for shift in (11, 6, 0))
            image[sy * STRIDE + sx] = colour
            count += 1
    clipped_rows = max(0, min(H, y + rows) - max(0, y))
    final_y = max(0, y) + clipped_rows if clipped_rows else y
    expected = (struct.pack(">3I", count, 0, final_y)
                + b"\x5a\x5a" * 8
                + struct.pack(">%dH" % len(image), *image)
                + b"\x5a\x5a" * 8)
    return dict(name=name, kind=kind, x=x, right=right, y=y, rows=rows,
                halves=halves, u=u, du=du, dv=dv, fraction=fraction,
                level=level, expected=expected)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("output", type=Path, help="new isolated output directory")
    ap.add_argument("--source", type=Path, default=ROOT / "TREX/m68030/trex_m68030.s")
    args = ap.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    source = args.source.read_text()
    start = source.index("\nspan_walk_half\n")
    end = source.index("\n\tifd\tTREX_OCCL\n; ---", start)
    kernel = source[start:end]
    callback_start = source.index("\nssi_hatari_rasterize_row\n")
    callback_end = source.index("\n\tendc", callback_start)
    callback = source[callback_start:callback_end]
    cells = sorted(set(re.findall(r"\braster_[a-z_]+\b", kernel)))
    callback_cells = sorted(set(re.findall(r"\bssi_[a-z_]+\b", callback)) - {"ssi_hatari_rasterize_row"})
    cases = [fixture("maximum opaque half"),
             fixture("split half continuity", halves=(111, 113)),
             fixture("transparent texels", "transparent"),
             fixture("all transparent", "transparent", du=0),
             fixture("semitransparency", "semi", rows=3),
             fixture("flat", "flat", rows=2),
             fixture("one row", rows=1),
             fixture("empty spans", x=10, right=10, rows=5),
             fixture("left/right clip", x=-3, right=245, rows=3),
             fixture("top clip", y=-5, rows=10),
             fixture("bottom clip", y=220, rows=10),
             fixture("below screen", y=224, rows=10),
             fixture("zero rows", rows=0),
             fixture("reverse UV wrap", u=255 * 256, du=-256, rows=3),
             fixture("low shade clamp", level=-256, rows=2),
             fixture("high shade clamp", level=16 * 256, rows=2),
             fixture("signed-word limits", du=32767, dv=-32768, fraction=2048, rows=2),
             fixture("wide positive U", du=32768, fraction=2048, rows=2),
             fixture("wide negative U", du=-32769, fraction=2048, rows=2),
             fixture("wide V only", dv=32768, fraction=2048, rows=2),
             fixture("wide modulo product", du=0x7FFFFF, dv=-0x800000, fraction=4095, rows=2),
             fixture("fractional left clip", x=-3, right=10, du=-32768,
                     dv=32767, fraction=1, rows=2)]
    for kind in ("opaque", "transparent", "semi", "flat"):
        case = fixture("SSI callback " + kind, kind, rows=3)
        case["callback"] = True
        case["expected"] = case["expected"][:8] + b"\0" * 4 + case["expected"][12:]
        cases.append(case)
    lines = ["TREX_SSI_HATARI=1", "GPU_PACKET_RESOLVE=104",
             "SCREEN_WIDTH=240", "SCREEN_HEIGHT=224", "FRAMEBUFFER_STRIDE=512",
             "\tsection text,code", "start:"]
    entries = dict(opaque="span_tex_opaque_loop", transparent="span_tex_loop",
                   semi="span_semi", flat="span_flat")
    for i, case in enumerate(cases):
        lines += ["\tmove.l #1,gouraud_enabled",
                  "\tlea framebuffer,a0", "\tmove.w #256*224-1,d0",
                  f".fill{i}: move.w #$0842,(a0)+", f"\tdbra d0,.fill{i}"]
        for guard in ("guard_before", "guard_after"):
            lines += [f"\tlea {guard},a0", "\tmoveq #7,d0",
                      f".{guard}{i}: move.w #$5a5a,(a0)+",
                      f"\tdbra d0,.{guard}{i}"]
        for cell in cells:
            lines.append(f"\tclr.l {cell}")
        values = dict(raster_xl=case["x"] * 4096 + case["fraction"],
                      raster_xr=case["right"] * 4096,
                      raster_y_current=case["y"], raster_rows=case["rows"],
                      raster_ul=case["u"], raster_du_dx=case["du"], raster_dv_dx=case["dv"],
                      raster_lvl=case["level"], raster_walk_clip=-1,
                      raster_flat_color=0x1234 << 16,
                      raster_lvl_shift=(9 if case["kind"] == "opaque" else 10) << 16)
        if "raster_prestep_wide" in cells:
            wide = not (-32768 <= case["du"] <= 32767 and -32768 <= case["dv"] <= 32767)
            values["raster_prestep_wide"] = 0xFF000000 if wide else 0
        for cell, value in values.items():
            lines.append(f"\tmove.l #{value},{cell}")
        palette = "palette_word" if case["kind"] == "opaque" else (
            "palette_semi" if case["kind"] == "semi" else "palette_long")
        lines += [f"\tmove.l #{palette},raster_clut_tint_base",
                  f"\tmove.l #framebuffer+({case['y']}*512),raster_fb_row",
                  f"\tmove.l #span_walk_half\\.{entries[case['kind']]},raster_span_entry",
                  "\tlea texture,a5"]
        if case.get("callback"):
            lines += ["\tclr.l raster_rows", "\tclr.l raster_y_current",
                      "\tlea callback_packet,a0", "\tmove.l a0,ssi_hatari_feed_packet_ptr",
                      f"\tmove.l #span_walk_half\\.{entries[case['kind']]},104(a0)",
                      "\tmove.l #texture,108(a0)",
                      ("\tmove.l #$1234,112(a0)" if case["kind"] == "flat" else
                       f"\tmove.l #{palette},112(a0)"),
                      f"\tmove.l #{9 if case['kind'] == 'opaque' else 10},116(a0)",
                      "\tclr.l 120(a0)", f"\tmove.l #{case['du']},52(a0)", "\tclr.l 56(a0)",
                      "\tmove.l #framebuffer,render_base",
                      "\tclr.l ssi_dma_hatari_feed_u", "\tclr.l ssi_dma_hatari_feed_v",
                      "\tclr.l ssi_dma_hatari_feed_shade", "\tclr.l ssi_dma_hatari_feed_x",
                      "\tmove.l #240,ssi_dma_hatari_feed_count", "\tclr.l ssi_dma_hatari_feed_y",
                      "\tmoveq #2,d7", f".callback{i}: bsr ssi_hatari_rasterize_row",
                      "\taddq.l #1,ssi_dma_hatari_feed_y", f"\tdbra d7,.callback{i}"]
        elif case["halves"]:
            for n in case["halves"]:
                lines += [f"\tmove.l #{n},raster_rows", "\tjsr span_walk_half"]
        else:
            lines.append("\tjsr span_walk_half")
        lines += ["\tmove.l raster_pixel_count,outblock",
                  "\tmove.l raster_rows,outblock+4",
                  "\tmove.l raster_y_current,outblock+8",
                  "\tclr.w -(sp)", f"\tpea file{i}", "\tmove.w #$3c,-(sp)",
                  "\ttrap #1", "\taddq.l #8,sp", "\tmove.w d0,handle",
                  "\tpea outblock", "\tmove.l #12+16+256*224*2+16,-(sp)",
                  "\tmove.w handle,-(sp)", "\tmove.w #$40,-(sp)", "\ttrap #1",
                  "\tlea 12(sp),sp", "\tmove.w handle,-(sp)",
                  "\tmove.w #$3e,-(sp)", "\ttrap #1", "\taddq.l #4,sp"]
    lines += ["\tclr.w -(sp)", "\ttrap #1", kernel, callback, "\tsection data,data"]
    for i in range(len(cases)):
        lines.append(f"file{i}: dc.b 'C{i:02d}.RES',0")
    lines += ["\teven", "texture:"]
    texture = bytes((x ^ y) & 1 for y in range(256) for x in range(256))
    (out / "texture.bin").write_bytes(texture)
    lines += [f"\tincbin '{out / 'texture.bin'}'"]
    for name, word in (("palette_word", True), ("palette_long", False), ("palette_semi", False)):
        lines.append(name + ":")
        vals = [((0x5678 if x & 1 else 0x1234) if word else
                 ((0x3F800 if name == "palette_semi" else 0x25678) if x & 1 else 0))
                for _ in range(16) for x in range(256)]
        for k in range(0, len(vals), 16):
            lines.append("\tdc." + ("w " if word else "l ")
                         + ",".join(f"${v:x}" for v in vals[k:k + 16]))
    lines += ["\tsection bss,bss", "handle: ds.w 1", "\teven", "gouraud_enabled: ds.l 1"]
    lines += [f"{cell}: ds.l 1" for cell in cells + callback_cells]
    lines += ["render_base: ds.l 1", "callback_packet: ds.l 32"]
    lines += ["outblock: ds.l 3", "guard_before: ds.w 8",
              "framebuffer: ds.w 256*224", "guard_after: ds.w 8"]
    asm = out / "check.s"
    asm.write_text("\n".join(lines) + "\n")
    subprocess.run([str(ROOT / "tools/vasm/vasmm68k_mot"), str(asm), "-quiet",
                    "-Felf", "-m68030", "-o", str(out / "check.o")], check=True)
    subprocess.run([str(ROOT / "tools/vlink/vlink"), str(out / "check.o"),
                    "-tos-fastload", "-b", "ataritos", "-s", "-e", "start",
                    "-o", str(out / "CHECK.TOS")], check=True)
    hatari = ROOT.parent / "F030Arcade/third_party/hatari/build/src/hatari"
    command = [str(hatari), "--machine", "falcon", "--cpulevel", "3",
               "--cpuclock", "16", "--mmu", "false", "--cpu-exact", "true",
               "--compatible", "true", "--videl-contention", "true",
               "--tos", str(ROOT.parent / "F030Arcade/third_party/tos/tos402.img"),
               "--fast-boot", "true", "--patch-tos", "true", "--memsize", "4",
               "--sound", "off", "--monitor", "rgb", "--benchmark",
               "--confirm-quit", "off", "--log-level", "fatal", "--alert-level", "fatal",
               "--harddrive", ".", "--auto", "C:\\CHECK.TOS", "--run-vbls", "5000"]
    with (out / "hatari.log").open("w") as log:
        proc = subprocess.Popen(command, cwd=out, stdout=log, stderr=log,
                                env={**os.environ, "SDL_VIDEODRIVER": "dummy"})
        try:
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                last = out / f"C{len(cases)-1:02d}.RES"
                if last.exists() and last.stat().st_size == len(cases[-1]["expected"]):
                    break
                if proc.poll() is not None:
                    raise RuntimeError("Harness exited before completing fixtures")
                time.sleep(0.05)
            else:
                raise RuntimeError("Harness timed out")
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
    for i, case in enumerate(cases):
        actual = (out / f"C{i:02d}.RES").read_bytes()
        if actual != case["expected"]:
            pos = next((p for p, (a, b) in enumerate(zip(actual, case["expected"])) if a != b),
                       min(len(actual), len(case["expected"])))
            raise AssertionError(f"{case['name']}: differs at byte {pos}")
        print("PASS", case["name"])


if __name__ == "__main__":
    main()
