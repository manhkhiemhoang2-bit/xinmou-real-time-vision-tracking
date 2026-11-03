import sys, os
sys.path.insert(0,".")
import numpy as np, check_alg_top_full as C, alg_ref as A
from gen_stim_top_full import BPL,H,W
d = C.parse(os.path.join("_mut_full","dump_top_full.txt"), quiet=True)
frames=6; F=3
img = C.images(frames)[F]
f,yall,xgall,valid = C.beat_axes(d, frames)
sel=(f==F)&valid&(yall>=2)&(xgall!=0)
y=yall[sel]; xg=xgall[sel]; gv=d["odv"][sel]
ex = C.variant_out(img, A.MODE_EDGE, {"src_dy":-1})
pb = C.pin_beats(ex)
wantb = pb[y*BPL+xg]
print("E2 ????? %d / %d"%((gv!=wantb).sum(), gv.size))
def pix(v,k):
    sh=np.uint64(24*(3-k))
    return ((v>>(sh+np.uint64(16)))&np.uint64(0xFF)).astype(np.int64)<<16 | \
           ((v>>(sh+np.uint64(8)))&np.uint64(0xFF)).astype(np.int64)<<8 | \
           ((v>>sh)&np.uint64(0xFF)).astype(np.int64)
def pix96(v):
    return [int(pix(np.array([v],dtype=np.uint64),k)[0]) for k in range(4)]
for i in range(4):
    print("beat %d: y=%d xg=%d"%(i,y[i],xg[i]))
    print("   got  raw=%024X -> %s"%(int(gv[i]), ["%06X"%p for p in pix96(int(gv[i]))]))
    print("   want raw=%024X -> %s"%(int(wantb[i]), ["%06X"%p for p in pix96(int(wantb[i]))]))
    print("   ex[%d, %d..%d] = %s"%(y[i], xg[i]*4, xg[i]*4+3, ["%02X%02X%02X"%tuple(int(t) for t in ex[y[i],xg[i]*4+p]) for p in range(4)]))
print("\nsrc ? y-1=%d ??? x=%d..%d: %s"%(y[0]-1,xg[0]*4,xg[0]*4+3,
      ["%02X%02X%02X"%tuple(int(t) for t in img[y[0]-1,xg[0]*4+p]) for p in range(4)]))
print("src+128 ??: %s"%["%02X%02X%02X"%tuple(int(min(int(t)+128,255)) for t in img[y[0]-1,xg[0]*4+p]) for p in range(4)])
