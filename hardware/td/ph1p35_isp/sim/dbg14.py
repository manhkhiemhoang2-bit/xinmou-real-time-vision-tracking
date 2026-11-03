import check_osd as C
hdr, rows = C.parse('osd_work/dump_osd.txt')
cfg = C.Config(*hdr); C.BPL = cfg.BPL

def pattern(b, tx, ty, ch_):
    x = 4*tx + ch_
    dx = x - cfg.TEXT_X
    gb = C.CHAR_BITS(C.char_rom_idx(C.char_code(dx//16, cfg)), (ty - cfg.TEXT_Y) & 0xF)
    return (gb >> (15 - dx % 16)) & 1

for i in range(2825, 2834):
    r = rows[i]
    if r['Ov'] != 1: continue
    b = (int(rows[i-1]['Id'],16)>>72)>>7
    ct = rows[i-1]
    dut = []
    for ch in range(4):
        got = (int(r['Od'],16)>>(72-24*ch))&0xFFFFFF
        dut.append(1 if got == C.OSD_TEXT_COLOR else 0)
    # try to explain DUT pattern by (char_idx, row)
    expl = []
    for ci in range(3):
        for row in range(16):
            pat = [ (C.CHAR_BITS(C.char_rom_idx(C.char_code(ci,cfg)), row) >> (15 - (4*ct['rx']+ch))) & 1 for ch in range(4) ]
            if pat == dut: expl.append((ci,row))
    print('cyc %d rx=%d ry=%d DUT=%s  explained by (char,row)=%s' % (r['cyc'], ct['rx'], ct['ry'], dut, expl[:4]))
