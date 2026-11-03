import check_osd as C
from collections import Counter
hdr, rows = C.parse('osd_work/dump_osd.txt')
cfg = C.Config(*hdr); C.BPL = cfg.BPL
cat = Counter(); samp = {}
for i in range(2, len(rows)):
    r = rows[i]
    if r['Ov'] != 1: continue
    src = rows[i-1]
    b = (int(src['Id'],16)>>72)>>7
    for ch in range(4):
        got = (int(r['Od'],16)>>(72-24*ch))&0xFFFFFF
        # text plane uses r_x/r_y of row i-1; logo plane uses r_x_logo/r_y_logo of row i-1
        wt, kt = C.expect_pix_at(cfg, b, r['rx'], r['ry'], ch)   # placeholder, replaced below
        want_t, kind_t = C.expect_pix_at(cfg, b, 0, 0, ch)
        if got == want_t: continue
        cat['mismatch'] += 1
        samp.setdefault('mismatch', (r['cyc'], r['rx'], r['ry'], r['lx'], r['ly'], ch, hex(got), hex(want_t)))
print(dict(cat))
print(samp.get('mismatch'))
