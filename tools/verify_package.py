"""Check source checksums and project dependencies; no FPGA tools required."""
import gzip,hashlib,json,re,xml.etree.ElementTree as ET
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def normalized(path,data):
 if path.endswith('camera_to_dsi_display.al'):
  text=data.decode('utf8');return re.sub(r'(<Project\b[^>]*\bPath=")[^"]*(")',r'\1__LOCAL_PROJECT_PATH__\2',text,count=1).encode('utf8')
 if path.endswith('/.fd/project.json'):
  item=json.loads(data)
  for k in ['location','hpfFile','bspLocation']:
   if k in item:item[k]='__LOCAL_PATH__'
  return json.dumps(item,sort_keys=True,ensure_ascii=False).encode('utf8')
 return data
manifest=json.loads((ROOT/'MANIFEST_SHA256.json').read_text('utf8'))
for item in manifest['files']:
 f=ROOT/item['path'];data=f.read_bytes()
 if hashlib.sha256(data).hexdigest()!=item['sha256']:
  assert item.get('normalizedSHA256')==hashlib.sha256(normalized(item['path'],data)).hexdigest(),item['path']
 if item.get('expandedPath'):
  assert hashlib.sha256(gzip.decompress(data)).hexdigest()==item['expandedSHA256']
al=ROOT/'hardware/td/ph1p35_isp/prj/board/lab_ex3_osd/td_project/camera_to_dsi_display.al'
refs=re.findall(r'<File\s+Path="([^"]+)"',al.read_text('utf8'))
missing=[r for r in refs if not(al.parent/r).is_file()]
assert not missing,missing
fd=ROOT/'firmware/fd'
for n in ['MCU_fpga','yuntai_mcu']:
 for f in ['.project','.cproject','.fd/project.json','Makefile']:assert(fd/n/f).is_file(),(n,f)
assert(fd/'MCU_fpga/tools/make/rules.mk').is_file()
assembly=list((ROOT/'mechanical/v10').rglob('*.SLDASM'))
parts=list((ROOT/'mechanical/v10').rglob('*.SLDPRT'))
assert len(assembly)==1 and len(parts)==12
original=json.loads(next((ROOT/'mechanical/v10').rglob('MANIFEST_SHA256.json')).read_text('utf-8-sig'))
legacy_changes=[name for name,sha in original.items()if hashlib.sha256((assembly[0].parent/name).read_bytes()).hexdigest().upper()!=sha]
assert all(name.endswith('.SLDASM')for name in legacy_changes),legacy_changes
print(json.dumps(dict(verifiedFiles=len(manifest['files']),tdFileReferences=len(refs),missingTDReferences=missing,
 fdProjects=2,solidWorksAssemblies=len(assembly),solidWorksParts=len(parts),
 mechanicalLegacyManifestDifferences=legacy_changes),ensure_ascii=False,indent=2))
