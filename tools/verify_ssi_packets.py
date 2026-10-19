#!/usr/bin/env python3
"""Independently decode the live flags=2 SSI packet and optional PIO capture.

Use --expect-crc-error for the diagnostic bit-flip capture. The payload must
still match every native PIO word. This never treats a rejected CRC as valid.
"""
import argparse
import binascii
from pathlib import Path
import struct


def decode(data, expect_crc_error=False):
    assert len(data) >= 32 and len(data) % 2 == 0, 'unaligned or short envelope'
    units = struct.unpack('>%dH' % (len(data) // 2), data)
    assert units[:2] == (0x5353, 0x0102), 'magic/version/packing'
    identity = (units[2] << 16) | units[3]
    declared = (units[6] << 16) | units[7]
    assert declared == len(units), 'capacity/received length'
    footer = units[-8:]
    assert footer[:2] == (0x5aa5, 0), 'footer magic/status'
    assert footer[2:4] == units[2:4], 'frame identity'
    count = footer[4]
    assert 1 <= count <= 32, 'survivor count'
    assert ((footer[5] << 16) | footer[6]) == declared == 16 + 27 * count, 'unit count'
    crc_good = binascii.crc_hqx(data[:-2], 0xffff) == footer[-1]
    assert crc_good != expect_crc_error, 'unexpected checksum result'
    words = []
    for offset in range(8, len(units) - 8, 3):
        a, b, c = units[offset:offset + 3]
        words += [(a << 8) | (b >> 8), ((b & 255) << 16) | c]
    assert len(words) == count * 18
    return words, {'frame': identity, 'base': units[4], 'generation': units[5],
                   'survivors': count, 'units': declared, 'crc_valid': crc_good}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('--pio', type=Path)
    parser.add_argument('--expect-crc-error', action='store_true')
    args = parser.parse_args()
    words, status = decode(args.capture.read_bytes(), args.expect_crc_error)
    if args.pio:
        data = args.pio.read_bytes()
        assert len(data) == 8 + len(words) * 4, 'PIO length'
        native = struct.unpack('>%dI' % (len(data) // 4), data)
        assert native[:2] == (0x700008, status['survivors']), 'PIO reply/count'
        assert tuple(words) == native[2:], 'decoded SSI words differ from PIO'
        status['pio_words_exact'] = len(words)
    print(status)


if __name__ == '__main__':
    main()
