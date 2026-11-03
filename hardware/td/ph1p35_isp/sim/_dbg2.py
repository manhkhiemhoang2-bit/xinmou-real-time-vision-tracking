import sys, json, numpy as np
sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0,'.')
import gen_stim_histeq as G, ref_histeq as R
man=json.load(open('histeq_scen.json',encoding='utf-8'))
s=[x for x in man['scenarios'] if x['name']=='lowc'][0]
fr=G.build_frames(s)
outs,info=R.ref_histeq(list(fr),s['W'],s['H'],en=[(s['en_mask']>>f)&1 for f in range(s['frames'])])
rows=[l.split() for l in open('dump_he_lowc.txt')]
byc={int(r[0]):r for r in rows}
rec={}
for r in rows:
    if r[6]!='1': continue
    c=int(r[0]); src=byc.get(c-2)
    if src is None or src[1]!='1': continue
    k=int(src[5]); rec[k]=(bytes.fromhex(src[4]),bytes.fromhex(r[9]))
BPF=s['bpf']
for f in range(s['frames']):
    ks=[k for k in sorted(rec) if f*BPF<=k<(f+1)*BPF]
    got={}
    for k in ks:
        ib,ob=rec[k]; got.setdefault(ib[0],set()).add(ob[0])
    mm=info['map'][f-1][0] if f>=1 else None
    bad=0; sample=[]
    for b in sorted(got):
        exp=int(mm[b]) if mm is not None else b
        gv=sorted(got[b])
        if gv!=[exp]:
            bad+=1
            if len(sample)<5: sample.append((b,gv,exp))
    print('frame %d: beats=%d  R 不符输入值 %d 个  样例=%s'%(f,len(ks),bad,sample))
