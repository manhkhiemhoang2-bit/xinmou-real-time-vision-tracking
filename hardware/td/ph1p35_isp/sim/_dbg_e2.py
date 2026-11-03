import sys, os
sys.path.insert(0,".")
import numpy as np, check_alg_top_full as C
from gen_stim_top_full import BPL,H,W
d = C.parse(os.path.join("_mut_full","dump_top_full.txt"), quiet=True)
frames=6; F=3
img = C.images(frames)[F]
f,yall,xgall,valid = C.beat_axes(d, frames)
sel=(f==F)&valid&(yall>=2)&(xgall!=0)
y=yall[sel]; xg=xgall[sel]; gv=d["odv"][sel]
print("??? %d, ?? y=%d xg=%d"%(y.size,y[0],xg[0]))
r=img[:,:,0].astype(np.int32); g=img[:,:,1].astype(np.int32); b=img[:,:,2].astype(np.int32)
key_lo=(r<<16)|(g<<8)|b; key_hi=((np.minimum(r+128,255)<<16)|(np.minimum(g+128,255)<<8)|np.minimum(b+128,255))
def pix(v,k):
    sh=np.uint64(24*(3-k))
    return (((v>>(sh+np.uint64(16)))&np.uint64(0xFF)).astype(np.int64)<<16)|(((v>>(sh+np.uint64(8)))&np.uint64(0xFF)).astype(np.int64)<<8)|((v>>sh)&np.uint64(0xFF)).astype(np.int64)
for i in range(6):
    x=xg[i]*4
    for p in range(4):
        vv=int(pix(gv[i:i+1],p)[0]); xx=x+p
        hit=(key_lo[:,xx]==vv)|(key_hi[:,xx]==vv)
        cand=np.nonzero(hit)[0]
        print(" ?%3d y=%-3d x=%-4d ?=%06X ???=%s  src??=%d  ??x?R=%d"
              %(i,y[i],xx,vv,cand.tolist()[:6],y[i]-1,img[y[i]-1,xx,0]))
