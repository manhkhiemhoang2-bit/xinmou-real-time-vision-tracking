import check_osd as C
from collections import Counter
hdr, rows = C.parse('osd_work/dump_osd.txt')
cfg = C.Config(*hdr); C.BPL = cfg.BPL
cat = Counter(); samp = {}
for i in range(1, len(rows)):
    r = rows[i]
    if r['Ov'] != 1: continue
    src = rows[i-1]; cor = rows[i-1]
    b = (int(src['Id'],16)>>72)>>7
    for ch in range(4):
        got = (int(r['Od'],16)>>(72-24*ch))&0xFFFFFF
        want, kind = C.expect_pix_at(cfg, b, cor['rx'], cor['ry'], ch)
        if got == want: continue
        if got == C.LOGO_FG: k = 'DUT_logo_unexpected'
        elif want == C.LOGO_FG: k = 'DUT_missing_logo'
        elif got == C.OSD_TEXT_COLOR: k = 'DUT_text_unexpected'
        elif want == C.OSD_TEXT_COLOR: k = 'DUT_missing_text'
        else: k = 'passthrough_differs'
        cat[k] += 1
        samp.setdefault(k, (r['cyc'], cor['rx'], cor['ry'], ch, hex(got), hex(want)))
for k, v in cat.most_common():
    print('%-22s %6d  e.g. cyc=%d rx=%d ry=%d ch=%d got=%s want=%s' % ((k, v) + samp[k]))
