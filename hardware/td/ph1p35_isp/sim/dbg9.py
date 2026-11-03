import check_osd as C
from collections import Counter
hdr, rows = C.parse('osd_work/dump_osd.txt')
cfg = C.Config(*hdr); C.BPL = cfg.BPL

def model(b, tx, ty, lx, ly, ch):
    x_t = 4 * tx + ch
    if (cfg.TEXT_X <= x_t < cfg.TEXT_X + cfg.N_CHAR_MAX*16) and (cfg.TEXT_Y <= ty < cfg.TEXT_Y+16):
        dx = x_t - cfg.TEXT_X
        gb = C.CHAR_BITS(C.char_rom_idx(C.char_code(dx//16, cfg)), (ty-cfg.TEXT_Y)&0xF)
        if (gb >> (15 - dx % 16)) & 1:
            return cfg.OSD_TEXT_COLOR, 'text'
    x_l = 4 * lx + ch
    if C.LOGO_HIT(ly - cfg.LOGO_Y, x_l - cfg.LOGO_X):
        return cfg.OSD_LOGO_COLOR, 'logo'
    return C.src_pix(b, ch), 'orig'

cat = Counter(); samp = {}
for i in range(2, len(rows)):
    r = rows[i]
    if r['Ov'] != 1: continue
    src = rows[i-1]
    b = (int(src['Id'],16)>>72)>>7
    ct = rows[i-1]; cl = rows[i-2]
    for ch in range(4):
        got = (int(r['Od'],16)>>(72-24*ch))&0xFFFFFF
        want, kind = model(b, ct['rx'], ct['ry'], cl['lx'], cl['ly'], ch)
        if got == want: continue
        if got == C.LOGO_FG: k='logo_extra'
        elif want == C.LOGO_FG: k='logo_missing'
        elif got == C.OSD_TEXT_COLOR: k='text_extra'
        elif want == C.OSD_TEXT_COLOR: k='text_missing'
        else: k='passthru'
        cat[k]+=1
        samp.setdefault(k, (r['cyc'], ct['rx'], ct['ry'], cl['lx'], cl['ly'], ch, hex(got), hex(want)))
for k,v in cat.most_common(): print('%-14s %5d  %s' % (k, v, samp[k]))
if not cat: print('ALL PIXELS MATCH')
