#!/usr/bin/env python3
"""Validate the actual local onboarding asset; no app launch or provider call."""
from pathlib import Path
import argparse, hashlib, json, shutil, subprocess, tempfile
root=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(); p.add_argument('--evidence-dir',type=Path); p.add_argument('--app-bundle',type=Path); args=p.parse_args()
out=args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-quick-start-'));out.mkdir(parents=True,exist_ok=True)
resources=root/'apps/ios/Rendprop/Resources'; movie=resources/'RendpropQuickStart.mp4'; transcript=resources/'RendpropQuickStart.txt'
assert movie.is_file() and transcript.is_file(),'The real local video and matching transcript must exist.'
assert 0<movie.stat().st_size<=10*1024*1024,'Bundled introduction must be at most10MiB.'
text=transcript.read_text().strip(); assert len(text)>100,'A readable matching transcript is required.'
probe=shutil.which('ffprobe'); assert probe,'ffprobe is required to verify the actual asset.'
result=subprocess.run([probe,'-v','error','-show_format','-show_streams','-of','json',str(movie)],capture_output=True,text=True,timeout=30)
(out/'ffprobe.json').write_text(result.stdout);(out/'ffprobe.stderr').write_text(result.stderr);assert result.returncode==0,'Actual introduction did not decode metadata.'
meta=json.loads(result.stdout); videos=[x for x in meta['streams'] if x['codec_type']=='video']; audio=[x for x in meta['streams'] if x['codec_type']=='audio'];assert len(videos)==1 and len(audio)==1,'Introduction must contain one video and one audio track.'
v=videos[0];a=audio[0]; duration=float(meta['format']['duration']); assert 0<duration<=120,'Introduction must not exceed the owner-approved two minutes.'
assert v['codec_name']=='h264' and a['codec_name']=='aac','Use native-compatible H264 and AAC.'
assert sorted([int(v['width']),int(v['height'])])==[1080,1920],'Introduction must be1080p.'
assert v['pix_fmt']=='yuv420p','Use broadly compatible8-bit4:2:0 video.'
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
receipt={'passed':True,'video':str(movie),'duration_seconds':duration,'bytes':movie.stat().st_size,'video_codec':v['codec_name'],'audio_codec':a['codec_name'],'width':v['width'],'height':v['height'],'pixel_format':v['pix_fmt'],'video_sha256':sha(movie),'transcript_sha256':sha(transcript),'transcript_characters':len(text),'scope':'Actual local asset metadata and optional compiled app resource byte binding; no player UI or subjective caption/narration review.'}
if args.app_bundle:
    for asset in [movie,transcript]:
        candidates=list(args.app_bundle.rglob(asset.name)); assert len(candidates)==1,f'Exactly one bundled{asset.name}required.'
        assert sha(candidates[0])==sha(asset),f'Bundled{asset.name}must match reviewedsource.'
    receipt['app_bundle']=str(args.app_bundle);receipt['bundled_asset_bytes_match']=True
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt))
