#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,os,struct,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[4]
OUT=Path(tempfile.mkdtemp(prefix='erase-real-mp4-',dir='/tmp'))
results=[]
def run(cmd):return subprocess.check_output([str(x) for x in cmd],cwd=ROOT,stderr=subprocess.STDOUT,text=True)
for name,seconds,fast,audio in [('clip-fast',4.8,True,True),('clip-tail',4.8,False,False),('tour-fast',600,True,True),('forgery-source',10,False,True)]:
 p=OUT/(name+'.mp4');cmd=['/opt/homebrew/bin/ffmpeg','-nostdin','-hide_banner','-loglevel','error','-f','lavfi','-i','color=c=blue:s=160x90:r=30']
 if audio:cmd+=['-f','lavfi','-i','sine=frequency=440:sample_rate=48000']
 cmd+=['-t',str(seconds),'-c:v','libx264','-preset','ultrafast','-pix_fmt','yuv420p']
 if audio:cmd+=['-c:a','aac']
 if fast:cmd+=['-movflags','+faststart']
 run([*cmd,p]);probe=json.loads(run(['/opt/homebrew/bin/ffprobe','-v','error','-show_entries','format=duration:stream=codec_type,duration','-of','json',p]))
 checked=json.loads(run(['/opt/homebrew/bin/deno','run','--deny-net','--allow-read='+str(OUT),ROOT/'tools/audit/call-20260919/web/probe-mp4-fixture.ts',p,str(seconds)]))
 checked['ffprobe']=probe;checked['sha256']=hashlib.sha256(p.read_bytes()).hexdigest();results.append(checked)
# Patch only mvhd to3seconds in an actual10second encoded A/V file.
src=OUT/'forgery-source.mp4';data=bytearray(src.read_bytes());off=0;patched=False
while off+8<=len(data):
 size=struct.unpack_from('>I',data,off)[0];kind=data[off+4:off+8];width=8
 if size==1:size=struct.unpack_from('>Q',data,off+8)[0];width=16
 if kind==b'moov':
  child=off+width
  while child+8<=off+size:
   n=struct.unpack_from('>I',data,child)[0];typ=data[child+4:child+8]
   if typ==b'mvhd':
    payload=child+8;version=data[payload];scaleoffset=payload+(12 if version==0 else 20)
    scale=struct.unpack_from('>I',data,scaleoffset)[0];struct.pack_into('>I' if version==0 else'>Q',data,scaleoffset+4,3*scale);patched=True;break
   child+=n
  break
 off+=size
assert patched
p=OUT/'forged-3s-header-10s-video.mp4';p.write_bytes(data)
checked=json.loads(run(['/opt/homebrew/bin/deno','run','--deny-net','--allow-read='+str(OUT),ROOT/'tools/audit/call-20260919/web/probe-mp4-fixture.ts',p,'3','refuse']))
checked['ffprobe']=json.loads(run(['/opt/homebrew/bin/ffprobe','-v','error','-show_entries','format=duration:stream=codec_type,duration','-of','json',p]));results.append(checked)
receipt={'passed':True,'fixtures':results,'limitations':'Bounded MP4 timeline/sample-table consistency; no video decode, no guarantee against a fully fabricated internally consistent container.'}
(OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(OUT/'receipt.json')
