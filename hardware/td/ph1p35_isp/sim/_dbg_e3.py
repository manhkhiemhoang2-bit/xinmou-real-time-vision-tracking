import sys, os
sys.path.insert(0,".")
import numpy as np, check_alg_top_full as C, alg_ref as A
from gen_stim_top_full import BPL,H,W,EDGE_K
d = C.parse(os.path.join("_mut_full","dump_top_full.txt"), quiet=True)
frames=6; F=3
img = C.images(frames)[F]
f,yall,xgall,valid = C.beat_axes(d, frames)
sel=(f==F)&valid&(yall>=2)&(xgall!=0)
y=yall[sel]; xg=xgall[sel]; gv=d["odv"][sel]
# 1) pix() ???????? beat ??? 4 ??? vs alg_ref ?????
print("beat0 raw = %024X"%int(gv[0]))
px = A.unpack_beats(np.array([[np.uint64(int(gv[0])>>32), np.uint64(int(gv[0])&0xFFFFFFFF)]],dtype=np.uint64))
print("alg_ref ??:", px[0].tolist())
def pix(v,k):
    sh=np.uint64(24*(3-k))
    return (((v>>(sh+np.uint64(16)))&np.uint64(0xFF)).astype(np.int64)<<16)|(((v>>(sh+np.uint64(8)))&np.uint64(0xFF)).astype(np.int64)<<8)|((v>>sh)&np.uint64(0xFF)).astype(np.int64)
mine=[tuple(int(x) for x in ((pix(gv[0:1],k)[0]>>16)&0xFF, (pix(gv[0:1],k)[0]>>8)&0xFF, pix(gv[0:1],k)[0]&0xFF)) for k in range(4)]
print("?? pix   :", mine)
# 2) ??? E2?????? vs variant_out(src=y-1)
ex = C.variant_out(img, A.MODE_EDGE, {"src_dy":-1})
xs = np.stack([xg*4+p for p in range(4)],axis=1)
want = np.stack([ex[y, xs[:,p]] for p in range(4)],axis=1).astype(np.int64)
key = np.stack([(want[:,p,0]<<16)|(want[:,p,1]<<8)|want[:,p,2] for p in range(4)],axis=1)
got = np.stack([pix(gv,p) for p in range(4)],axis=1)
print("??? vs variant_out(y-1)??? %d / %d"%((got!=key).sum(), got.size))
bad=np.nonzero((got!=key).any(axis=1))[0]
print("? 3 ?????", bad[:3].tolist())
for i in bad[:3]:
    print("  y=%d xg=%d ??=%s ??=%s"%(y[i],xg[i],key[i].tolist(),got[i].tolist()))
print("?? y-1 ??????(?8?):", img[y[0]-1, :8].tolist())
