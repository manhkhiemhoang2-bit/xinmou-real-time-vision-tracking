import check_osd as C
hdr, rows = C.parse('osd_work/dump_osd.txt')
cfg = C.Config(*hdr); C.BPL = cfg.BPL
def hit(rx, ry, ch, rowshift, colshift):
    x = 4*rx + ch
    if not (cfg.TEXT_Y <= ry < cfg.TEXT_Y+16): return 0
    if not (cfg.TEXT_X <= x < cfg.TEXT_X+256): return 0
    dx = x - cfg.TEXT_X
    gb = C.CHAR_BITS(C.char_rom_idx(C.char_code(dx//16, cfg)), ((ry-cfg.TEXT_Y)+rowshift)&0xF)
    return (gb >> (15 - (dx%16))) & 1
for off in (0,1):
    for rs in (0,1):
        for cs in (0,1):
            ok=tot=0
            for i in range(2,len(rows)):
                r=rows[i]
                if r['Ov']!=1: continue
                b=(int(rows[i-1]['Id'],16)>>72)>>7
                c=rows[i-off]
                for ch in range(4):
                    xx=4*c['rx']+ch
                    if not (cfg.TEXT_Y<=c['ry']<cfg.TEXT_Y+16): continue
                    if not (cfg.TEXT_X<=xx<cfg.TEXT_X+256): continue
                    got=(int(r['Od'],16)>>(72-24*ch))&0xFFFFFF
                    p=hit(c['rx'],c['ry'],ch,rs,cs)
                    w=cfg.OSD_TEXT_COLOR if p else C.src_pix(b,ch)
                    tot+=1
                    if got==w: ok+=1
            print('off=%d rowshift=%d colshift=%d -> %d/%d (%.1f%%)' % (off,rs,cs,ok,tot,100.0*ok/max(tot,1)))
