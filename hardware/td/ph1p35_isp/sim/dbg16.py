import check_osd as C
hdr, rows = C.parse('osd_work/dump_osd.txt')
cfg = C.Config(*hdr); C.BPL = cfg.BPL
# Compare text-plane only, model vs DUT, with coordinate source rows[i-1]
ok = tot = 0
mism = []
for i in range(2, len(rows)):
    r = rows[i]
    if r['Ov'] != 1: continue
    b = (int(rows[i-1]['Id'],16)>>72)>>7
    c = rows[i-1]
    xb = 4*c['rx']
    if not (cfg.TEXT_Y <= c['ry'] < cfg.TEXT_Y+16): continue
    if not (cfg.TEXT_X <= xb < cfg.TEXT_X+256): continue
    tot += 4
    for ch in range(4):
        got = (int(r['Od'],16)>>(72-24*ch))&0xFFFFFF
        want, kind = C.expect_pix_at(cfg, b, c['rx'], c['ry'], ch)
        if got == want: ok += 1
        elif len(mism) < 8:
            mism.append((r['cyc'], c['rx'], c['ry'], ch, xb+ch, hex(got), hex(want), kind))
print('text region: %d/%d match' % (ok, tot))
for m in mism: print('  cyc=%d rx=%d ry=%d ch=%d x=%d got=%s want=%s kind=%s' % m)
# what does the model say the first few characters are?
print('char slots:', [chr(C.char_code(i,cfg)) for i in range(8)])
