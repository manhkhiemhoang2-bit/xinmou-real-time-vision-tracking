import sys, collections
sys.stdout.reconfigure(encoding="utf-8")
C_IV, C_IL, C_IU, C_ID = 1, 2, 3, 4
C_OV, C_OL, C_OU, C_OD, C_OM = 8, 9, 10, 11, 12
C_BBV, C_BBX0, C_BBX1, C_BBY0, C_BBY1, C_BBPC = 13, 14, 15, 16, 17, 18
NAMES = {C_OL: 'tlast', C_OU: 'tuser', C_OD: 'tdata', C_OM: 'mode',
         C_BBV: 'bbv', C_BBX0: 'x0', C_BBX1: 'x1', C_BBY0: 'y0', C_BBY1: 'y1', C_BBPC: 'pix'}


def parse(p):
    rows = []
    for ln in open(p, 'r', encoding='ascii', errors='replace'):
        f = ln.split()
        if len(f) < 21:
            continue
        rows.append(f)
    return rows


ref = parse('dump_top_ref.txt')
bub = parse('dump_top_bub.txt')


def outs(rows):
    return [f for f in rows if f[C_OV] == '1']


ro, bo = outs(ref), outs(bub)
print("out beats ref=%d bub=%d" % (len(ro), len(bo)))
cols = collections.Counter()
bad = []
for k in range(min(len(ro), len(bo))):
    d = [c for c in NAMES if ro[k][c] != bo[k][c]]
    if d:
        bad.append(k)
        for c in d:
            cols[NAMES[c]] += 1
print("bad beats: %d  first=%s" % (len(bad), bad[:12]))
print("bad column histogram:", dict(cols))
print("tdata-only bad? tdata diffs:", cols['tdata'])
print()
print("first 6 bad beats detail (ref/bub):")
for k in bad[:6]:
    print(" beat %d  cyc ref=%s bub=%s" % (k, ro[k][0], bo[k][0]))
    for c in NAMES:
        if ro[k][c] != bo[k][c]:
            print("     %-6s ref=%-6s bub=%-6s" % (NAMES[c], ro[k][c], bo[k][c]))
print()
print("all bad beat indices:", bad)
