import sys, json, numpy as np
sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0,'.')
import gen_stim_histeq as G, ref_histeq as R
man=json.load(open('histeq_scen.json',encoding='utf-8'))
s=[x for x in man['scenarios'] if x['name']=='lowc'][0]
fr=G.build_frames(s)
outs,info=R.ref_histeq(list(fr),s['W'],s['H'],en=[(s['en_mask']>>f)&1 for f in range(s['frames'])])
h0=info['hist'][0]; m0=info['map'][0]
print('hist R bins(flat->(c,b)):', [(int(i//256),int(i%256)) for i in np.flatnonzero(h0)][:8])
print('map R bins 58..64:', m0[0][58:65].tolist(), ' map R[91]=',int(m0[0][91]))
print('map G bins 58..64:', m0[1][58:65].tolist(), ' map B[58..64]:', m0[2][58:65].tolist())
rows=[l.split() for l in open('dump_he_lowc.txt')]
byc={int(r[0]):r for r in rows}
rec={}
for r in rows:
    if r[6]!='1': continue
    c=int(r[0]); src=byc.get(c-2)
    if src is None or src[1]!='1': continue
    k=int(src[5]); ob=bytes.fromhex(r[9]); ib=bytes.fromhex(src[4])
    rec[k]=(ib,ob)
f0=[rec[k] for k in sorted(rec) if k<128]; f1=[rec[k] for k in sorted(rec) if 128<=k<256]
print('paired beats f0=%d f1=%d'%(len(f0),len(f1)))
print('frame0 out==in:', all(ib==ob for ib,ob in f0))
got={}
for ib,ob in f1: got.setdefault(ib[0],set()).add(ob[0])
print('R map recovered vs expected:')
for b in sorted(got)[:6]+sorted(got)[-3:]:
    print('   in=%3d got=%s exp=%d'%(b,sorted(got[b]),int(m0[0][b])))
