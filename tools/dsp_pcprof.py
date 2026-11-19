#!/usr/bin/env python3
"""DSP PC-range profile of a TREX DSP image (OPTIMIZATION.md 2.8).

The corrected Hatari fork books every executed DSP instruction's clocks to
the P-address ranges named in HATARI_DSP_PCPROF and rewrites the totals to
dsp_pcprof.txt in the run directory.  This tool derives those ranges from the
labels of an ASM56000 listing, so they follow the code, and turns the result
into milliseconds per frame.

  dsp_pcprof.py env TREX/dsp/build/TREXDSP.LST
      prints the environment assignments for the measurement run
  dsp_pcprof.py report TREX/dsp/build/TREXDSP.LST <run>/dsp_pcprof.txt

The listing must be the one of the image that is measured: TREXDSP.LST is
overwritten by every DSP assembly, so copy it right after building.
"""
import argparse
import re

CLOCK_HZ = 32_000_000.0
LABEL = re.compile(r"^\d+\s+([A-Za-z_][A-Za-z0-9_]*)\s*$")
# An instruction line carries source text; a bare extension word does not.
CODE = re.compile(r"^\d+\s+P:([0-9A-F]{4})\s+[0-9A-F]{6}(?:\s+[0-9A-F]{6})?\s+\S")
COMMANDS = {0x04: "BUILD_TRIANGLES (the next chunk's list)",
            0x06: "GET_TRIANGLES (fetch of a finished chunk)",
            0x0a: "PREPASS (order keys, the frame's start)",
            0x0c: "SET_ANIMATED_FRAME", 0x0d: "LOAD_ANIMATION_GAIT",
            0x0e: "APPLY_ANIMATION_TARGET", 0x0f: "FINISH_ANIMATED_FRAME",
            0x44: "GET_BANDS"}


def read_listing(path):
    labels, pending, last = {}, [], None
    for line in open(path, errors="replace"):
        match = LABEL.match(line.rstrip("\n"))
        if match:
            pending.append(match.group(1))
            continue
        match = CODE.match(line)
        if match:
            last = int(match.group(1), 16)
            for name in pending:
                labels.setdefault(name, last)
            pending = []
    return labels, last


def plan(path):
    """Return (ranges, start, callers, cmd): ranges is a list of (key, lo, hi)."""
    labels, last = read_listing(path)
    at = labels.__getitem__
    ranges = []

    def add(key, lo, hi):
        ranges.append((key, lo, hi))

    waits = ["ss_wait_end", "ss_pixel_wait"]
    if "ss_header_wait0" in labels:
        waits.append("ss_header_wait0")
    waits += ["ss_header_wait1", "ss_header_wait2"]
    for name in waits:
        add(name + ".jclr", at(name), at(name) + 1)
        add(name + ".movep", at(name) + 2, at(name) + 2)
    add("walker", at("span_stream_walk"), at("lookup_projected_z") - 1)
    add("span", at("make_triangle_span"), at("span_stream_walk") - 1)
    add("rx.jclr", at("receive_word"), at("receive_word") + 1)
    add("rx.tail", at("receive_word") + 2, at("send_word") - 1)
    add("tx.jclr", at("send_word"), at("send_word") + 1)
    add("tx.tail", at("send_word") + 2, at("receive_animation_delta") - 1)
    add("build", at("command_build_triangles"), at("command_get_triangles") - 1)
    add("prelight", at("prelight_run"), at("transform_vertices") - 1)
    add("xform", at("transform_vertices"), at("make_triangle_zkey") - 1)
    add("shade", at("make_triangle_zkey"), at("lookup_projected_xy") - 1)
    area_end = at("band_mark") if "band_mark" in labels else at("make_triangle_span")
    add("area", at("lookup_projected_xy"), area_end - 1)
    if "band_mark" in labels:
        add("band", at("band_mark"), at("make_triangle_span") - 1)
    add("order", at("command_prepass"), last)
    add("flush", at("triangle_reply"), at("triangle_reply") + 1)
    start = at("command_set_animated_frame")
    callers = (at("receive_word"), at("receive_animation_delta") - 1)
    cmd = (at("receive_word") + 2, at("main_loop") + 1)
    return ranges, start, callers, cmd


def cmd_env(args):
    ranges, start, callers, cmd = plan(args.listing)
    print("export HATARI_DSP_PCPROF_START=%04X" % start)
    print("export HATARI_DSP_PCPROF_CALLERS=%04X-%04X" % callers)
    print("export HATARI_DSP_PCPROF_CMD=%04X,%04X" % cmd)
    print("export HATARI_DSP_PCPROF=" + ",".join("%04X-%04X" % (lo, hi) for _, lo, hi in ranges))


def cmd_report(args):
    ranges, _, _, _ = plan(args.listing)
    total, rows, commands = None, [], []
    for line in open(args.profile):
        part = line.split()
        if not part:
            continue
        if part[0] == "total":
            total = (int(part[1]), int(part[2]))
        elif part[0] == "cmd":
            commands.append((int(part[1], 16), int(part[2]), int(part[3])))
        elif part[0] != "ret":
            rows.append((part[0], int(part[1]), int(part[2])))
    if total is None or len(rows) != len(ranges):
        raise SystemExit("profile does not match this listing's %d ranges" % len(ranges))
    data = {}
    for (key, lo, hi), (name, clocks, instrs) in zip(ranges, rows):
        if name.lower() != "%04x-%04x" % (lo, hi):
            raise SystemExit("range %s was measured as %s: wrong listing" % (key, name))
        data[key] = (clocks, instrs)
    frames = args.frames

    def ms(clocks):
        return clocks / CLOCK_HZ * 1000.0 / frames

    print("DSP clocks booked: %.2f ms/frame over %d frames" % (ms(total[0]), frames))
    print("SSI transmitter, waiting = JCLR clocks beyond the one poll per unit:")
    ssi_wait = units = 0
    for name in ("ss_pixel_wait", "ss_header_wait0", "ss_header_wait1", "ss_header_wait2",
                 "ss_wait_end"):
        if name + ".jclr" not in data:
            continue
        sent = data[name + ".movep"][1]
        waiting = data[name + ".jclr"][0] - 6 * sent
        ssi_wait += waiting
        units += sent
        print("  %-16s %8.0f units/frame  %7.2f ms/frame  %5.1f clocks/unit"
              % (name, sent / frames, ms(waiting), waiting / sent if sent else 0.0))
    print("  %-16s %8.0f units/frame  %7.2f ms/frame" % ("all", units / frames, ms(ssi_wait)))
    rx_words = data["rx.tail"][1] // 3      # movep, nop, rts
    tx_words = data["tx.tail"][1] // 2      # movep, rts
    rx_wait = data["rx.jclr"][0] - 6 * rx_words
    tx_wait = data["tx.jclr"][0] - 6 * tx_words
    moves = (data["rx.jclr"][0] - rx_wait + data["rx.tail"][0]
             + data["tx.jclr"][0] - tx_wait + data["tx.tail"][0])
    flush = data["flush"][0]
    items = [
        ("stream walker, arithmetic", data["walker"][0] - ssi_wait),
        ("stream walker, waiting on the SSI transmitter", ssi_wait + flush),
        ("span setup (make_triangle_span, span_div, UV fetch)", data["span"][0]),
        ("BUILD chunk loop and record pack", data["build"][0] - flush),
        ("zkey and lighting (make_triangle_zkey, _shade)", data["shade"][0]),
        ("area, bounding box, projected lookups", data["area"][0]),
        ("band marking and GET_BANDS", data.get("band", (0, 0))[0]),
        ("prelight_run's own loop", data["prelight"][0]),
        ("transform and project", data["xform"][0]),
        ("order keys and index reload", data["order"][0]),
        ("host port: waiting for the host to send", rx_wait),
        ("host port: waiting for the host to read", tx_wait),
        ("host port: word moves (%d in, %d out a frame)"
         % (rx_words / frames, tx_words / frames), moves),
    ]
    items.append(("everything else (dispatch, animation, morph)",
                  total[0] - sum(clocks for _, clocks in items)))
    print("where the DSP's clocks go, ms/frame:")
    for name, clocks in items:
        print("  %-52s %8.2f  %5.1f%%" % (name, ms(clocks), 100.0 * clocks / total[0]))
    if commands:
        print("main loop kept waiting for a command, by the command that ended the wait:")
        for number, clocks, count in commands:
            print("  $%02x %-42s %7.2f ms/frame  %5.1f a frame  %6.3f ms each"
                  % (number, COMMANDS.get(number, "?"), ms(clocks), count / frames,
                     clocks / CLOCK_HZ * 1000.0 / count))
        print("  %-46s %7.2f ms/frame" % ("all", ms(sum(c for _, c, _ in commands))))


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="mode", required=True)
    env = sub.add_parser("env")
    env.add_argument("listing")
    env.set_defaults(run=cmd_env)
    report = sub.add_parser("report")
    report.add_argument("listing")
    report.add_argument("profile")
    report.add_argument("--frames", type=int, default=265)
    report.set_defaults(run=cmd_report)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
