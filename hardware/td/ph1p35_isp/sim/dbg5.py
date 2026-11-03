import check_osd as C
hdr, rows = C.parse('osd_work/dump_osd.txt')
cfg = C.Config(*hdr)
# find the first cycle where the model expects a logo hit, then look at what the DUT did
for i in range(1, len(rows)):
    r = rows[i]
    if not r['Ov']: continue
    p = rows[i-1]
    b = (int(p['Id'],16)>>72)>>7
    rx, ry = r['rx'], r['ry']
    for ch in range(4):
        v, kind = C.expect_pix_at(cfg, b, rx, ry, ch)
        if kind == 'logo':
            print('first model-logo at cyc=%d rx=%d ry=%d ch=%d x=%d y=%d' % (r['cyc'], rx, ry, ch, 4*rx+ch, ry))
            print('  DUT: Od=%s logo_probe=%s  Got %06X' % (r['Od'], r['L'], (int(r['Od'],16)>>(72-24*ch))&0xFFFFFF))
            raise SystemExit
