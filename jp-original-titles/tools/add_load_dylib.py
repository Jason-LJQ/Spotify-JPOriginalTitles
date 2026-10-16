#!/usr/bin/env python3
"""Append an LC_LOAD_DYLIB command into the header padding of a thin arm64 Mach-O.

Usage: add_load_dylib.py <binary> <dylib install name>
"""
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0x0C
LC_CODE_SIGNATURE = 0x1D

path, name = sys.argv[1], sys.argv[2].encode()
data = bytearray(open(path, 'rb').read())
magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, _ = struct.unpack_from('<IiiIIIII', data, 0)
if magic != MH_MAGIC_64:
    sys.exit('not a thin 64-bit Mach-O')

header_size = 32
offset = header_size
first_section = len(data)
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from('<II', data, offset)
    if cmd == LC_LOAD_DYLIB:
        str_off = struct.unpack_from('<I', data, offset + 8)[0]
        existing = bytes(data[offset + str_off:offset + cmdsize]).split(b'\0', 1)[0]
        if existing == name:
            sys.exit('already present')
    if cmd == LC_SEGMENT_64:
        nsects = struct.unpack_from('<I', data, offset + 64)[0]
        for i in range(nsects):
            sect = offset + 72 + i * 80
            sect_offset = struct.unpack_from('<I', data, sect + 48)[0]
            if sect_offset:
                first_section = min(first_section, sect_offset)
    offset += cmdsize

cmd_size = (24 + len(name) + 1 + 7) & ~7
end = header_size + sizeofcmds
if end + cmd_size > first_section:
    sys.exit(f'not enough header padding: {first_section - end} < {cmd_size}')
if any(data[end:end + cmd_size]):
    sys.exit('header padding is not empty')

# dylib_command: cmd, cmdsize, name offset, timestamp, current_version, compatibility_version
command = struct.pack('<IIIIII', LC_LOAD_DYLIB, cmd_size, 24, 2, 0x10000, 0x10000) + name
command += b'\0' * (cmd_size - len(command))
data[end:end + cmd_size] = command
struct.pack_into('<II', data, 16, ncmds + 1, sizeofcmds + cmd_size)
open(path, 'wb').write(data)
print(f'added {name.decode()} ({cmd_size} bytes, padding left {first_section - end - cmd_size})')
