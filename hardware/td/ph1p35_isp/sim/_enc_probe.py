import sys; sys.path.insert(0,".")
lines=["%d 1 0 0 %024X 1 0 0 %024X 5 1 1234 2047 0 2047 0"%(i,0x1122334455667788+i,0xAABBCCDDEEFF0011+i) for i in range(2)]
for l in lines: print(len(l), repr(l[:40]), repr(l[30:48]), repr(l[47:71]), repr(l[71:]))
