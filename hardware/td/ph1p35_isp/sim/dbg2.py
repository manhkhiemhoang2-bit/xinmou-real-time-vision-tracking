import check_osd as C
hdr, rows = C.parse("osd_work/dump_osd.txt")
cfg = C.Config(*hdr); C.BPL = cfg.BPL
exp, ref = C.expected_stream(rows, cfg)
print("i cyc | DUT(rx,ry) | ref[i-1] | ref[i-2] | beat(i-1) | Od_pix0")
for i in range(6, 18):
    r = rows[i]
    d = (r["rx"], r["ry"])
    a = ref[i-1] if i>=1 else None
    b = ref[i-2] if i>=2 else None
    bp = rows[i-1]["beat"] if i>=1 else None
    o0 = C.decode_pix((int(r["Od"],16)>>72)&0xFFFFFF)
    print("%2d %3d | %s | %s | %s | %s | %s" % (i, r["cyc"], d, a, b, bp, o0))
