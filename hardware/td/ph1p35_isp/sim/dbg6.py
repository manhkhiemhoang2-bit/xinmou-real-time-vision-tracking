import check_osd as C
hdr, rows = C.parse('osd_work/dump_osd.txt')
cfg = C.Config(*hdr); C.BPL = cfg.BPL
# model without text/logo: just test source-pixel identity, to find the data phase
best = []
for di in (1, 2, 3):
    for ci in (0, 1, 2):
        ok = tot = 0
        for i in range(max(di, ci), len(rows)):
            r = rows[i]
            if r['Ov'] != 1: continue
            src = rows[max(i - di, 0)]
            cor = rows[max(i - ci, 0)]
            if cor['Ov'] == 0 and ci != 0: pass
            v = int(r['Od'], 16)
            for ch in range(4):
                got = (v >> (72 - 24 * ch)) & 0xFFFFFF
                b = (int(src['Id'], 16) >> 72) >> 7
                x = 4 * cor['rx'] + ch
                y = cor['ry']
                want, kind = C.expect_pix_at(cfg, b, x // 4, y, ch)
                tot += 1
                if got == want: ok += 1
        best.append((ok / max(tot, 1), di, ci, tot))
for frac, di, ci, tot in sorted(best, reverse=True)[:6]:
    print('data_lag=%d coord_lag=%d -> %d/%d (%.2f%%)' % (di, ci, int(frac*tot), tot, frac*100))
