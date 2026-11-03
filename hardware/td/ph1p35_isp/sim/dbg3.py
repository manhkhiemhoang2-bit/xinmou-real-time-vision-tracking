import check_osd as C
hdr, rows = C.parse("osd_work/dump_osd.txt")
cfg = C.Config(*hdr); C.BPL = cfg.BPL
# For each row, find which source beat reproduces the observed O_tdata pixel 0
print("i cyc | Od_pix0 | matches(src_beat) | rows[i-2].beat | rows[i-1].beat")
for i in range(7, 22):
    r = rows[i]
    got = (int(r["Od"],16)>>72)&0xFFFFFF
    hits = [b for b in range(0, 40) if C.src_pix(b,0) == got]
    b2 = rows[i-2]["beat"] if i>=2 else None
    b1 = rows[i-1]["beat"]
    print("%3d %3d | %06X | %-18s | %-14s | %s" % (i, r["cyc"], got, hits, b2, b1))
