import check_osd as C
hdr, rows = C.parse("osd_work/dump_osd.txt")
print("rows parsed:", len(rows), "last row fields:", len(rows[-1]))
# verify rules over ALL rows with valid output
r_data = r_ctrl = r_coord = 0
tot = 0
for i in range(1, len(rows)-1):
    r = rows[i]
    if r["Ov"] != 1: continue
    tot += 1
    got = (int(r["Od"],16)>>72)&0xFFFFFF
    # rule A: data beat = beat column of row i-1
    if C.src_pix(rows[i-1]["beat"], 0) == got: r_data += 1
    # rule B: control = input of row i-1
    if (r["Ov"],r["Ol"],r["Ou"]) == (rows[i-1]["Iv"],rows[i-1]["Il"],rows[i-1]["Iu"]): r_ctrl += 1
    # rule C: coords = counters of row i-1
    if (r["rx"],r["ry"]) == (rows[i-1]["xg"],rows[i-1]["yp"]): r_coord += 1
print("valid rows: %d" % tot)
print("data rule  (beat col[i-1])      : %d/%d" % (r_data, tot))
print("ctrl rule  (I ctrl[i-1])        : %d/%d" % (r_ctrl, tot))
print("coord rule (counters[i-1])      : %d/%d" % (r_coord, tot))
