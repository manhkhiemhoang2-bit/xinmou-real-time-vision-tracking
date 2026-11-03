import check_osd as C
hdr, rows = C.parse('osd_work/dump_osd.txt')
cfg = C.Config(*hdr); C.BPL = cfg.BPL
# For the DUT text hits, which glyph row index explains them?
for i in range(2825, 2836):
    r = rows[i]
    if r['Ov'] != 1: continue
    ct = rows[i-1]
    b = (int(ct['Id'],16)>>72)>>7
    dut = []
    for ch in range(4):
        got = (int(r['Od'],16)>>(72-24*ch))&0xFFFFFF
        dut.append(1 if got == C.OSD_TEXT_COLOR else 0)
    xb = 4*ct['rx']
    ci = (xb - cfg.TEXT_X)//16
    cands = []
    for row in range(16):
        gb = C.CHAR_BITS(C.char_rom_idx(C.char_code(ci,cfg)), row)
        pat = [(gb >> (15 - ((xb - cfg.TEXT_X) % 16 + ch))) & 1 for ch in range(4)]
        if pat == dut: cands.append(row)
    print('cyc %d beat=%d rx=%d ry=%d ci=%d DUT=%s -> glyphrows %s (model row=%d)' % (
        r['cyc'], b, ct['rx'], ct['ry'], ci, dut, cands, (ct['ry']-cfg.TEXT_Y)&0xF))
