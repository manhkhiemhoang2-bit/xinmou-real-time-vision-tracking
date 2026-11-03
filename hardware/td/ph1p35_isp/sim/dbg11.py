import check_osd as C
hdr, rows = C.parse('osd_work/dump_osd.txt')
cfg = C.Config(*hdr); C.BPL = cfg.BPL
best = []
for tl in (1,2):
    for ll in (0,1,2):
        ok = tot = 0
        for i in range(2, len(rows)):
            r = rows[i]
            if r['Ov'] != 1: continue
            b = (int(rows[i-1]['Id'],16)>>72)>>7
            ct = rows[i-tl]; cl = rows[i-ll]
            for ch in range(4):
                got = (int(r['Od'],16)>>(72-24*ch))&0xFFFFFF
                # text plane only
                x_t = 4*ct['rx']+ch
                kind = 'orig'; w = C.src_pix(b,ch)
                if (cfg.TEXT_X <= x_t < cfg.TEXT_X+256) and (cfg.TEXT_Y <= ct['ry'] < cfg.TEXT_Y+16):
                    dx = x_t - cfg.TEXT_X
                    gb = C.CHAR_BITS(C.char_rom_idx(C.char_code(dx//16,cfg)), (ct['ry']-cfg.TEXT_Y)&0xF)
                    if (gb>>(15-dx%16))&1: kind='text'; w = cfg.OSD_TEXT_COLOR
                if kind == 'orig':
                    x_l = 4*cl['rx']+ch
                    if C.LOGO_HIT(cl['ry']-cfg.LOGO_Y, x_l-cfg.LOGO_X):
                        kind='logo'; w = cfg.OSD_LOGO_COLOR
                tot += 1
                if got == w: ok += 1
        best.append((ok/max(tot,1), tl, ll, tot))
for f, tl, ll, tot in sorted(best, reverse=True):
    print('text_lag=%d logo_lag=%d -> %d/%d (%.2f%%)' % (tl, ll, int(f*tot), tot, f*100))
