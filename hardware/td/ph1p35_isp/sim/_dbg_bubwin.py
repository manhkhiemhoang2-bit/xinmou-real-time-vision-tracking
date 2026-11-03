import sys
sys.stdout.reconfigure(encoding="utf-8")
HDR = "cyc  Iv Il Iu | Ov Ol Ou | bbv x0    x1    y0    y1    pix"


def parse(p):
    rows = []
    for ln in open(p, 'r', encoding='ascii', errors='replace'):
        f = ln.split()
        if len(f) < 27:
            continue
        rows.append(f)
    return rows


ref = parse('dump_top_ref.txt')
bub = parse('dump_top_bub.txt')


def show(rows, name, cyc_lo, cyc_hi):
    print("---- %s : cycles %d..%d ----" % (name, cyc_lo, cyc_hi))
    print(HDR)
    for f in rows:
        c = int(f[0])
        if cyc_lo <= c <= cyc_hi:
            print("%4s  %s  %s %s %s | %s %s %s | %s %-5s %-5s %-5s %-5s %s" % (
                f[0], f[1], f[2], f[3], f[4][:8],
                f[8], f[9], f[10], f[13], f[14], f[15], f[16], f[17], f[18]))


show(ref, 'REF', 60, 80)
show(bub, 'BUB', 200, 225)
