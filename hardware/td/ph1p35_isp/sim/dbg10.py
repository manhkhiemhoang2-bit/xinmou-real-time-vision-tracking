import check_osd as C
hdr, rows = C.parse('osd_work/dump_osd.txt')
cfg = C.Config(*hdr); C.BPL = cfg.BPL

def plane(b, tx, ty, lx, ly, ch):
    x_t = 4*tx + ch
    if (cfg.TEXT_X <= x_t < cfg.TEXT_X + cfg.N_CHAR_MAX*16) and (cfg.TEXT_Y <= ty < cfg.TEXT_Y+16):
        dx = x_t - cfg.TEXT_X
        gb = C.CHAR_BITS(C.char_rom_idx(C.char_code(dx//16, cfg)), (ty-cfg.TEXT_Y)&0xF)
        if (gb >> (15 - dx%16)) & 1: return 'text'
    x_l = 4*lx + ch
    if C.LOGO_HIT(ly - cfg.LOGO_Y, x_l - cfg.LOGO_X): return 'logo'
    return 'orig'

# search best (text_lag, logo_lag)
best = []
for tl in (0,1,2):
    for ll in (0,1,2):
        ok = tot = 0
        for i in range(2, len(rows)):
            r = rows[i]
            if r['Ov'] != 1: continue
            b = (int(rows[i-1]['Id'],16)>>72)>>7
            ct = rows[i-tl]; cl = rows[i-ll]
            for ch in range(4):
                got = (int(r['Od'],16)>>(72-24*ch))&0xFFFFFF
                want, kind = C.expect_pix_at(cfg, b, ct['rx'], ct['ry'], ch)
                if kind == 'text' and got == want: ok += 1; tot += 1; continue
                k = plane(b, ct['rx'], ct['ry'], cl['rx'], cl['ry'], ch)
                w = {'text': cfg.OSD_TEXT_COLOR, 'logo': cfg.OSD_LOGO_COLOR, 'orig': C.src_pix(b,ch)}[k]
                tot += 1
                if got == w: ok += 1
        best.append((ok/max(tot,1), tl, ll, tot))
for f, tl, ll, tot in sorted(best, reverse=True)[:5]:
    print('text_lag=%d logo_lag=%d -> %d/%d (%.2f%%)' % (tl, ll, int(f*tot), tot, f*100))
