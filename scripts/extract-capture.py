#!/usr/bin/env python3
"""Extract one TCP session from a local Ethernet/IPv4 pcapng reference capture.

Usage: python3 -I scripts/extract-capture.py CAPTURE CLIENT_PORT OUTPUT_PREFIX
Only recorded bytes are read; this script never opens a network connection.
"""
import pathlib
import struct
import sys

capture = pathlib.Path(sys.argv[1]).read_bytes()
port = int(sys.argv[2])
prefix = pathlib.Path(sys.argv[3])
endian = "<"
interfaces = []
segments = {"c2s": {}, "s2c": {}}
at = 0
while at < len(capture):
    if capture[at:at + 4] == b"\x0a\x0d\x0d\x0a":
        endian = "<" if capture[at + 8:at + 12] == b"\x4d\x3c\x2b\x1a" else ">"
        interfaces = []
    kind, length = struct.unpack_from(endian + "II", capture, at)
    if length < 12 or at + length > len(capture) or struct.unpack_from(endian + "I", capture, at + length - 4)[0] != length:
        raise ValueError("Invalid capture block")
    if kind == 1:
        interfaces.append(struct.unpack_from(endian + "H", capture, at + 8)[0])
    elif kind == 6:
        interface, _, _, size, _ = struct.unpack_from(endian + "IIIII", capture, at + 8)
        packet = capture[at + 28:at + 28 + size]
        link = interfaces[interface]
        if link == 1 and packet[12:14] == b"\x08\x00":
            ip = packet[14:]
        elif link == 113 and packet[14:16] == b"\x08\x00":
            ip = packet[16:]
        elif link == 276 and packet[:2] == b"\x08\x00":
            ip = packet[20:]
        else:
            at += length
            continue
        if len(ip) >= 20 and ip[0] >> 4 == 4 and ip[9] == 6:
            total = struct.unpack_from(">H", ip, 2)[0]
            tcp = ip[(ip[0] & 15) * 4:total]
            if len(tcp) >= 20:
                source, destination, sequence = struct.unpack_from(">HHI", tcp)
                side = "c2s" if (source, destination) == (port, 10700) else "s2c" if (source, destination) == (10700, port) else None
                payload = tcp[(tcp[12] >> 4) * 4:]
                if side and payload:
                    old = segments[side].get(sequence)
                    if old is not None and old != payload:
                        raise ValueError("Conflicting retransmission")
                    segments[side][sequence] = payload
    at += length
for side, packets in segments.items():
    if not packets:
        raise ValueError(f"No {side} stream for port {port}")
    start = min(packets)
    output = bytearray()
    for sequence, payload in sorted(packets.items()):
        offset = sequence - start
        if offset > len(output):
            raise ValueError("Gap in TCP capture")
        overlap = min(len(payload), len(output) - offset)
        if output[offset:offset + overlap] != payload[:overlap]:
            raise ValueError("Conflicting TCP overlap")
        output.extend(payload[overlap:])
    path = pathlib.Path(str(prefix) + f".{side}.bin")
    path.write_bytes(output)
    print(f"{path.name}: {len(output)} recorded bytes")
