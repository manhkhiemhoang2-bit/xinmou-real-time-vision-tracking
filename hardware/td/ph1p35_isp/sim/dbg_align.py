import check_osd as C
hdr, rows = C.parse("osd_work/dump_osd.txt")
cfg = C.Config(*hdr)
C.BPL = cfg.BPL
print("row cyc | Id(beat0 pix0)      | Od(beat,l,r,c)              | beat_col cnt pre")
for i in range(5, 14):
    r = rows[i]
    Id = int(r["Id"],16); Od = int(r["Od"],16)
    d0 = C.decode_pix((Id >> 72) & 0xFFFFFF)
    o0 = C.decode_pix((Od >> 72) & 0xFFFFFF)
    # ??????? Od ?? beat
    ob = o0[0]*cfg.BPL + o0[1] if o0 else None
    print("%3d %3d | I=%06X %s | O=%06X %s beat=%s | Ib=%d cnt=%d/%d rxy=%d/%d" % (
        i, r["cyc"], (Id>>72)&0xFFFFFF, d0, (Od>>72)&0xFFFFFF, o0, ob,
        r["beat"], r["xg"], r["yp"], r["rx"], r["ry"]))
