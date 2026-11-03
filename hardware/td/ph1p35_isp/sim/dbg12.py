import check_osd as C
from collections import Counter
hdr, rows = C.parse('osd_work/dump_osd.txt')
cfg = C.Config(*hdr); C.BPL = cfg.BPL
cat = Counter(); samp = {}
for i in range(2, len(rows)):
    r = rows[i]
    if r['Ov'] != 1: continue
    b = (int(rows[i-1]['Id'],16)>>72)>>7
    ct = rows[i-1]
    for ch in range(4):
        got = (int(r['Od'],16)>>(72-24*ch))&0xFFFFFF
        want, kind = C.expect_pix_at(cfg, b, ct['rx'], ct['ry'], ch)
        if got == want: continue
        if got == C.LOGO_FG: k='DUT_logo_extra'
        elif want == C.LOGO_FG: k='DUT_logo_missing'
        elif got == C.OSD_TEXT_COLOR: k='DUT_text_extra'
        elif want == C.OSD_TEXT_COLOR: k='DUT_text_missing'
        else: k='passthru_differs'
        cat[k]+=1
        samp.setdefault(k, (r['cyc'], ct['rx'], ct['ry'], ch, hex(got), hex(want), b))
for k,v in cat.most_common(): print('%-18s %5d  %s' % (k,v,samp[k]))
