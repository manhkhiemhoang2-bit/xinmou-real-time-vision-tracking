import check_osd as C
hdr, rows = C.parse('osd_work/dump_osd.txt')
cfg = C.Config(*hdr); C.BPL = cfg.BPL
# Is the LOGO decision consistent with coords of rows[i] or rows[i-1]?
# Compare DUT logo hits against model logo plane for both sources.
for off in (0,1):
    tp = fp = fn = 0
    for i in range(2, len(rows)):
        r = rows[i]
        if r['Ov'] != 1: continue
        c = rows[i-off]
        for ch in range(4):
            xx = 4*c['rx']+ch
            in_txt = (cfg.TEXT_Y <= c['ry'] < cfg.TEXT_Y+16) and (cfg.TEXT_X <= xx < cfg.TEXT_X+256)
            if in_txt: continue
            hit_model = C.LOGO_HIT(c['ry']-cfg.LOGO_Y, xx-cfg.LOGO_X)
            # DUT: is O_tdata equal to the logo color?
            got = (int(r['Od'],16)>>(72-24*ch))&0xFFFFFF
            hit_dut = (got == cfg.OSD_LOGO_COLOR)
            if hit_model and hit_dut: tp += 1
            elif hit_model and not hit_dut: fn += 1
            elif hit_dut and not hit_model: fp += 1
    print('coord rows[i-%d]: true_pos=%d false_neg(DUT missing)=%d false_pos(DUT extra)=%d' % (off,tp,fn,fp))
