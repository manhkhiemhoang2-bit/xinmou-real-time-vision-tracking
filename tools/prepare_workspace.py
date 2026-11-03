"""Run with Python 3 after extracting or cloning this project."""
import argparse,gzip,hashlib,json,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('--skip-stimuli',action='store_true');args=parser.parse_args()
td=ROOT/'hardware/td/ph1p35_isp/prj/board/lab_ex3_osd/td_project'
al=td/'camera_to_dsi_display.al'
text=al.read_text('utf8')
text=re.sub(r'(<Project\b[^>]*\bPath=")[^"]*(")',lambda m:m[1]+td.as_posix()+m[2],text,count=1)
al.write_text(text,encoding='utf8')
fd=ROOT/'firmware/fd'
for name in ['MCU_fpga','yuntai_mcu']:
 f=fd/name/'.fd/project.json';data=json.loads(f.read_text('utf8'));data['location']=(fd/name).as_posix()
 if name=='MCU_fpga':data['hpfFile']=(fd/name/'camera_to_dsi_display.hpf').as_posix()
 else:data['bspLocation']=(fd/'MCU_fpga').as_posix()
 f.write_text(json.dumps(data,ensure_ascii=False,indent=4),encoding='utf8')
if not args.skip_stimuli:
 for item in json.loads((ROOT/'MANIFEST_SHA256.json').read_text('utf8'))['files']:
  if 'expandedPath'not in item:continue
  data=gzip.decompress((ROOT/item['path']).read_bytes())
  assert hashlib.sha256(data).hexdigest()==item['expandedSHA256']
  target=ROOT/item['expandedPath'];target.write_bytes(data);print('Restored:',target.relative_to(ROOT))
print('TD and FD project paths configured. Original HDL, C code, CAD and bitstreams were not changed.')
