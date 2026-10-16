#!/usr/bin/env python3
"""Read-only RPKG (v1 'GKPR' and v2 '2KPR') reader written for M6-C2 from the public RPKG-Tool source (src/import_rpkg.cpp,
src/hash.h, src/crypto.cpp, src/extract_from_rpkg.cpp at glacier-modding/RPKG-Tool main): lists every entry
(hash, type, sizes, flags, dependencies) and extracts a resource (8-byte XOR key from crypto.cpp, LZ4 block). Independent of
the framework's rpkg-cli. Usage: rpkg_read.py list <file> [--filter HEX,...] | extract <file> <HEX> <out>"""
import struct, sys, os

XOR = bytes([0xDC, 0x45, 0xA6, 0x9C, 0xD3, 0x72, 0x4C, 0xAB])  # crypto.cpp xor_array (8 bytes)

def lz4_block_decompress(src, out_size):
    out = bytearray(); i = 0; n = len(src)
    while i < n:
        token = src[i]; i += 1
        lit = token >> 4
        if lit == 15:
            while True:
                b = src[i]; i += 1; lit += b
                if b != 255: break
        out += src[i:i + lit]; i += lit
        if i >= n: break
        off = src[i] | (src[i + 1] << 8); i += 2
        if off == 0: raise ValueError("lz4: zero offset")
        ml = (token & 15) + 4
        if (token & 15) == 15:
            while True:
                b = src[i]; i += 1; ml += b
                if b != 255: break
        start = len(out) - off
        if start < 0: raise ValueError("lz4: offset beyond output")
        for k in range(ml): out.append(out[start + k])
    if len(out) != out_size: raise ValueError(f"lz4: decompressed {len(out)} != expected {out_size}")
    return bytes(out)

def read_rpkg(path):
    with open(path, 'rb') as f:
        magic = f.read(4)
        if magic == b'2KPR': version = 2; v2hdr = f.read(9)
        elif magic == b'GKPR': version = 1; v2hdr = b''
        else: raise ValueError(f"not an RPKG file: {magic!r}")
        hash_count, hht_size, hrt_size, patch_count = struct.unpack('<IIII', f.read(16))
        size = os.path.getsize(path)
        # patch detection as import_rpkg.cpp does it (v1 and v2 offsets)
        base = 0x10 if version == 1 else 0x19   # the hash tables' offset for a non-patch file
        is_patch = False
        if hash_count == 0 and patch_count > 0: is_patch = True
        elif patch_count * 8 + (0x24 if version == 1 else 0x2D) >= size: is_patch = False
        else:
            f.seek(patch_count * 8 + (0x1B if version == 1 else 0x24)); zero = f.read(1)[0]; test_off = struct.unpack('<Q', f.read(8))[0]
            if test_off == hht_size + hrt_size + patch_count * 8 + (0x14 if version == 1 else 0x1D) and zero == 0: is_patch = True
        patch_list = []
        if is_patch and patch_count > 0:
            f.seek(base + 4); patch_list = list(struct.unpack('<%dQ' % patch_count, f.read(8 * patch_count)))
        off = base + (patch_count * 8 + 4 if is_patch else 0)
        f.seek(off); tables = f.read(hht_size + hrt_size)
    pos = 0; entries = []
    for i in range(hash_count):
        h, data_off, data_size = struct.unpack_from('<QQI', tables, pos); pos += 20
        entries.append({'hash': f"{h:016X}", 'offset': data_off, 'data_size_field': data_size})
    for e in entries:
        t = tables[pos:pos + 4][::-1].decode('ascii', 'replace'); pos += 4
        ref_size, ref_dummy, size_final, size_mem, size_vmem = struct.unpack_from('<IIIII', tables, pos); pos += 20
        e.update(type=t, reference_table_size=ref_size, size_final=size_final, size_in_memory=size_mem, size_in_video_memory=size_vmem)
        ds = e['data_size_field']
        if (ds & 0x3FFFFFFF) != 0:
            e['lz4'] = True; e['stored_size'] = ds & 0x3FFFFFFF; e['xored'] = bool(ds & 0x80000000)
        else:
            e['lz4'] = False; e['stored_size'] = size_final; e['xored'] = bool(ds & 0x80000000)
        deps = []
        if ref_size > 0:
            cnt = struct.unpack_from('<I', tables, pos)[0]; pos += 4
            ordering = cnt & 0xC0000000; cnt &= 0x3FFFFFFF
            if ordering != 0xC0000000: raise ValueError("unexpected dependency ordering flag (not H3)")
            flags = list(tables[pos:pos + cnt]); pos += cnt
            hashes = struct.unpack_from('<%dQ' % cnt, tables, pos); pos += 8 * cnt
            deps = [(f"{hh:016X}", fl) for hh, fl in zip(hashes, flags)]
        e['deps'] = deps
    return {'path': path, 'version': version, 'is_patch': is_patch, 'patch_list': [f"{p:016X}" for p in patch_list], 'hash_count': hash_count, 'entries': entries, 'v2hdr': v2hdr.hex()}

def extract(path, e):
    with open(path, 'rb') as f:
        f.seek(e['offset']); raw = bytearray(f.read(e['stored_size']))
    if e['xored']:
        for i in range(len(raw)): raw[i] ^= XOR[i % 8]
    return lz4_block_decompress(bytes(raw), e['size_final']) if e['lz4'] else bytes(raw)

if __name__ == '__main__':
    cmd = sys.argv[1]; path = sys.argv[2]
    r = read_rpkg(path)
    if cmd == 'list':
        flt = set(x.upper() for x in sys.argv[4].split(',')) if len(sys.argv) > 4 and sys.argv[3] == '--filter' else None
        print(f"{os.path.basename(path)}: RPKG v{r['version']} header {r['v2hdr']} patch={r['is_patch']} entries={r['hash_count']} patch_list={len(r['patch_list'])} {r['patch_list'] if len(r['patch_list']) <= 8 else ''}")
        for e in r['entries']:
            if flt and e['hash'] not in flt: continue
            print(f"  {e['hash']} {e['type']} stored={e['stored_size']} final={e['size_final']} lz4={e['lz4']} xored={e['xored']} deps={len(e['deps'])}")
            for d, fl in e['deps']: print(f"      dep {d} flag 0x{fl:02X}")
    elif cmd == 'extract':
        want = sys.argv[3].upper(); out = sys.argv[4]
        e = next(x for x in r['entries'] if x['hash'] == want)
        data = extract(path, e); open(out, 'wb').write(data)
        import hashlib; print(f"extracted {e['hash']} {e['type']} {len(data)} bytes sha256 {hashlib.sha256(data).hexdigest()} -> {out}")
