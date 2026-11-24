#!/usr/bin/env python3
"""Independent Python executable specification. Does NOT run or prove Zig source."""
from dataclasses import dataclass
import random
import unittest

@dataclass(frozen=True)
class ID:
    index: int
    generation: int

class Table:
    def __init__(self, mask, cap):
        self.mask, self.cap = mask, cap
        self.ids = []
        self.cols = {c: [] for c in range(3) if mask & (1 << c)}
    def values(self, row):
        return {c: col[row] for c, col in self.cols.items()}
    def append(self, e, values):
        assert len(self.ids) < self.cap and set(values) == self.cols.keys()
        row = len(self.ids); self.ids.append(e)
        for c, col in self.cols.items(): col.append(values[c])
        return row
    def erase(self, row):
        moved = self.ids[-1] if row != len(self.ids)-1 else None
        self.ids[row] = self.ids[-1]; self.ids.pop()
        for col in self.cols.values(): col[row] = col[-1]; col.pop()
        return moved

class World:
    def __init__(self, cap=16, configs=None):
        self.tables = {m: Table(m,n) for m,n in (configs or {m:cap for m in range(8)}).items()}
        self.gen = [1]*cap; self.free = list(range(cap-1,-1,-1)); self.directory = {}
    def spawn(self, data):
        mask = sum(1 << c for c in data)
        t = self.tables.get(mask)
        if t is None or len(t.ids)==t.cap or not self.free: return None
        i = self.free.pop(); e = ID(i, self.gen[i]); self.directory[e] = mask,t.append(e,data); return e
    def lookup(self,e):
        if e not in self.directory: return None
        m,r = self.directory[e]; return self.tables[m].values(r)
    def remove_row(self,m,r):
        moved = self.tables[m].erase(r)
        if moved is not None: self.directory[moved] = (m,r)
    def mutate(self,e,c,value):
        old = self.lookup(e)
        if old is None or ((c in old) == (value is not None)): return False
        src,r = self.directory[e]
        data = dict(old)
        if value is None: data.pop(c)
        else: data[c] = value
        dst = sum(1 << key for key in data)
        t = self.tables.get(dst)
        if t is None or len(t.ids)==t.cap: return False
        self.directory[e] = dst,t.append(e,data)
        self.remove_row(src,r)
        return True
    def despawn(self,e):
        if e not in self.directory: return False
        m,r=self.directory.pop(e); self.remove_row(m,r)
        self.gen[e.index]+=1; self.free.append(e.index); return True
    def audit(self):
        inverse = {}
        for m,t in self.tables.items():
            assert len(t.ids)<=t.cap
            assert all(len(col)==len(t.ids) for col in t.cols.values())
            for row,e in enumerate(t.ids):
                assert e not in inverse and e.generation==self.gen[e.index]
                inverse[e]=(m,row)
        assert inverse==self.directory
        assert len(set(e.index for e in inverse))==len(inverse)
        assert set(self.free).isdisjoint(e.index for e in inverse)
        assert len(self.free)+len(inverse)==len(self.gen)

def conflict(a,b):
    ar,aw,_=a; br,bw,_=b
    return bool(aw & (br|bw) or bw & ar)

def plan(systems):
    n=len(systems); remaining=set(range(n)); waves=[]
    deps=[set(s[2])|{j for j in range(i) if conflict(systems[j],s)} for i,s in enumerate(systems)]
    if any(not d<=remaining for d in deps): raise ValueError('unknown dependency')
    while remaining:
        ready={i for i in remaining if not (deps[i]&remaining)}
        if not ready: raise ValueError('cycle')
        waves.append(ready); remaining-=ready
    return waves,deps

class Tests(unittest.TestCase):
    def test_random_churn(self):
        rng=random.Random(541); w=World(); ref={}; dead=[]
        for step in range(10000):
            op=rng.randrange(4)
            if not ref or op==0:
                data={c:step for c in range(3) if rng.randrange(2)}
                e=w.spawn(data)
                if e is not None: ref[e]=data
                else: self.assertEqual(len(ref),len(w.gen))
            elif op==1:
                e=rng.choice(list(ref)); self.assertTrue(w.despawn(e)); ref.pop(e); dead.append(e)
            else:
                e=rng.choice(list(ref)); c=rng.randrange(3)
                value=None if c in ref[e] else step
                self.assertTrue(w.mutate(e,c,value))
                if value is None: ref[e].pop(c)
                else: ref[e][c]=value
            w.audit(); self.assertEqual({e:w.lookup(e) for e in w.directory},ref)
            if dead: self.assertIsNone(w.lookup(rng.choice(dead)))
    def test_failed_migration(self):
        w=World(3,{1:2,3:1}); a=w.spawn({0:1}); b=w.spawn({0:2,1:7})
        self.assertFalse(w.mutate(a,1,10)); self.assertFalse(w.mutate(a,2,10))
        self.assertEqual(w.lookup(a),{0:1}); self.assertEqual(w.lookup(b),{0:2,1:7}); w.audit()
    def test_waves(self):
        rng=random.Random(891)
        for _ in range(1000):
            n=rng.randrange(1,33)
            systems=[(rng.randrange(256),rng.randrange(256),{j for j in range(i) if rng.randrange(12)==0}) for i in range(n)]
            waves,deps=plan(systems); stages={i:k for k,w in enumerate(waves) for i in w}
            self.assertEqual(set(stages),set(range(n)))
            for i in range(n):
                self.assertTrue(all(stages[j]<stages[i] for j in deps[i]))
                for j in range(i):
                    if conflict(systems[i],systems[j]): self.assertNotEqual(stages[i],stages[j])
        with self.assertRaises(ValueError): plan([(0,1,{1}),(1,0,set())])
    def test_workload_checksum(self):
        # Same specification as run_ecs.py, evaluated via an explicit loop.
        n,r=200000,80
        rows=[i for i in range(n)]
        for _ in range(r):
            for i in range(0,n,2): rows[i]+=i%17+1
        self.assertEqual(sum(x+i%256 for i,x in enumerate(rows)),sum(i+(r*(i%17+1) if i%2==0 else 0)+i%256 for i in range(n)))

if __name__=='__main__': unittest.main()
