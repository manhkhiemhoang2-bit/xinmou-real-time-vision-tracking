import check_osd as C
hdr, rows = C.parse('osd_work/dump_osd.txt')
cfg = C.Config(*hdr); C.BPL = cfg.BPL
# Compare hit SETS (over the whole logo region) between DUT and model, per coord source.
for off in (0,1):
    tset = fset = agree = tot = 0
    for i in range(2, len(rows)):
        r = rows[i]
        if r['Ov'] != 1: continue
        c = rows[i-off]
        for ch in range(4):
            xx = 4*c['rx']+ch; yy = c['ry']
            if not (cfg.LOGO_X <= xx < cfg.LOGO_X+128): continue
            if not (cfg.LOGO_Y <= yy < cfg.LOGO_Y+64): continue
            # skip the text band so the two planes don't interfere
            if (cfg.TEXT_Y <= yy < cfg.TEXT_Y+16) and (cfg.TEXT_X <= xx < cfg.TEXT_X+256): continue
            got = (int(r['Od'],16)>>(72-24*ch))&0xFFFFFF
            dut_hit = (got == cfg.OSD_LOGO_COLOR)
            mod_hit = C.LOGO_HIT(yy-cfg.LOGO_Y, xx-cfg.LOGO_X)
            tot += 1
            if dut_hit == mod_hit: agree += 1
            elif dut_hit: fset += 1
            else: tset += 1
    print('coords rows[i-%d]: agree=%d/%d  DUT_extra=%d  DUT_missing=%d' % (off, agree, tot, fset, tset))
