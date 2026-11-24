#!/usr/bin/env python3
"""Independent Python wire-format and cost-model checks. Not Zig execution."""
from pathlib import Path
import itertools, random, struct, unittest

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / 'src' / 'binary' / 'fixtures' / 'two_nodes.rvc'
HEADER = struct.Struct('<4sHH6I')
NODE = struct.Struct('<I3f2I')

def make_fixture():
    records = [(7, (1.25, -2., 3.), b'root'), (9, (4., 5., 6.), b'child')]
    nodes, labels = bytearray(), bytearray()
    for ident, pos, label in records:
        nodes.extend(NODE.pack(ident, *pos, len(labels), len(label)))
        labels.extend(label)
    end = HEADER.size + len(nodes)
    return HEADER.pack(b'RVC1', 1, HEADER.size, len(records), HEADER.size, end, len(labels), end + len(labels), 0) + nodes + labels

def parse_fixture(blob):
    import math
    if len(blob) < HEADER.size: raise ValueError('header')
    magic, version, hs, count, off, labels_off, labels_size, total, reserved = HEADER.unpack_from(blob)
    if (magic, version, hs, off, reserved) != (b'RVC1', 1, HEADER.size, HEADER.size, 0): raise ValueError('header')
    if total != len(blob) or labels_off != hs + count * NODE.size or labels_off + labels_size != total: raise ValueError('extent')
    records = []
    for i in range(count):
        ident, x, y, z, offset, n = NODE.unpack_from(blob, off + i * NODE.size)
        if not all(map(math.isfinite, (x,y,z))) or offset + n > labels_size: raise ValueError('record')
        records.append((ident, (x,y,z), blob[labels_off+offset:labels_off+offset+n]))
    return records

def count_intervals(base, n, stride, fields, line):
    last, total = -1, 0
    for i, (offset,size) in itertools.product(range(n),fields):
        lo = (base + i*stride + offset)//line
        hi = (base + i*stride + offset + size-1)//line
        total += max(0, hi-max(lo-1,last))
        last = hi
    return total

class ReferenceTests(unittest.TestCase):
    def test_fixture(self):
        b = FIXTURE.read_bytes()
        self.assertEqual(b, make_fixture())
        self.assertEqual(parse_fixture(b), [(7,(1.25,-2.,3.),b'root'),(9,(4.,5.,6.),b'child')])
        for n in range(len(b)):
            with self.assertRaises(ValueError): parse_fixture(b[:n])
        m = bytearray(b); struct.pack_into('<I',m,32+16,0xffffffff)
        with self.assertRaises(ValueError): parse_fixture(m)
    def test_cost_model(self):
        r = random.Random(42)
        for _ in range(1000):
            stride, n, base, line = r.randint(1,128),r.randint(0,40),r.randint(0,128),r.randint(1,128)
            cut = sorted(r.sample(range(stride+1),r.randint(0,min(8,stride+1))))
            fields = [(x,y-x) for x,y in zip(cut[::2],cut[1::2])]
            truth = { (base+i*stride+o+b)//line for i in range(n) for o,s in fields for b in range(s) }
            self.assertEqual(count_intervals(base,n,stride,fields,line),len(truth))

if __name__ == '__main__':
    if '--generate' in __import__('sys').argv:
        FIXTURE.parent.mkdir(parents=True, exist_ok=True)
        FIXTURE.write_bytes(make_fixture())
        __import__('sys').argv.remove('--generate')
    unittest.main()
