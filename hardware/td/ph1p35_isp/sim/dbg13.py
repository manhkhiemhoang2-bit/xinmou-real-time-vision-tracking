import check_osd as C
hdr, rows = C.parse('osd_work/dump_osd.txt')
cfg = C.Config(*hdr); C.BPL = cfg.BPL
print("cyc beat rx ry | DUT text-hit pattern (per ch) vs model")
for i in range(2820, 2846):
    r = rows[i]
    if r['Ov'] != 1: continue
    b = (int(rows[i-1]['Id'],16)>>72)>>7
    ct = rows[i-1]
    dut = []
    mod = []
    for ch in range(4):
        got = (int(r['Od'],16)>>(72-24*ch))&0xFFFFFF
        want, kind = C.expect_pix_at(cfg, b, ct['rx'], ct['ry'], ch)
        dut.append('T' if got == C.OSD_TEXT_COLOR else ('.' if got == C.src_pix(b,ch) else '?'))
        mod.append('T' if kind=='text' else '.')
    print('%4d %4d %2d %3d | DUT=%s MODEL=%s' % (r['cyc'], b, ct['rx'], ct['ry'], ''.join(dut), ''.join(mod)))
