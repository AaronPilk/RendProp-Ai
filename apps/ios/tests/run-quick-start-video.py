#!/usr/bin/env python3
"""Validate the complete offline training film and its transcript/timeline.

There is no arbitrary length or byte ceiling. Native media compatibility,
chapter/voice continuity and bundle-byte identity are the release gates.
"""
from __future__ import annotations

import argparse
import array
import hashlib
import json
import math
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[3]
RESOURCES=ROOT/'apps/ios/Rendprop/Resources'
SOURCE=ROOT/'docs/marketing/quick-start-20261028'
MOVIE=RESOURCES/'RendpropQuickStart.mp4'
TRANSCRIPT=RESOURCES/'RendpropQuickStart.txt'
CHAPTERS=['Find your way','Build the home','Photos & AI','Make a video',
          'Optional video tools','Publish the website','Follow up & manage','Account & usage']


def checked(command: list[str], timeout: int=30) -> bytes:
    result=subprocess.run(command,capture_output=True,timeout=timeout)
    assert result.returncode==0, f"Command failed: {command[:5]}: {result.stderr[-1000:]!r}"
    return result.stdout


def sha(path: Path) -> str:
    digest=hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser=argparse.ArgumentParser()
    parser.add_argument('--evidence-dir',type=Path)
    parser.add_argument('--app-bundle',type=Path)
    args=parser.parse_args()
    out=args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-quick-start-'))
    out.mkdir(parents=True,exist_ok=True)
    assert MOVIE.is_file() and MOVIE.stat().st_size>0 and TRANSCRIPT.is_file(), 'Bundled media missing'
    scenes=json.loads((SOURCE/'scenes.json').read_text())['scenes']
    timeline=json.loads((SOURCE/'timeline.json').read_text())
    vtt=(SOURCE/'captions.vtt').read_text()
    transcript=TRANSCRIPT.read_text().strip()
    assert len(scenes)>=38 and len(timeline['scenes'])==len(scenes), 'Training scene coverage incomplete'
    assert len(transcript.split())>1500, 'Transcript must include narration and on-screen directions'
    assert vtt.startswith('WEBVTT\n') and vtt.count('-->')>=len(scenes), 'Timed captions incomplete'
    for scene,item in zip(scenes,timeline['scenes']):
        assert scene['id']==item['id'] and scene['title'] in transcript, 'Scene/transcript mismatch'
        assert scene['narration'] in transcript, 'Narration missing from transcript'
        assert item['end']>item['start'] and item['audio_seconds']>0, 'Empty scene or audio segment'
    assert [x['title'] for x in timeline['chapters']]==CHAPTERS, 'Chapter order mismatch'
    for phrase in ['Activity','Needs attention','Use on listing website','Restore purchases',
                   'Check pending purchase','Aerial intro','Signature Estate','Coastal Luxe',
                   'MLS link','three-dimensional capture']:
        assert phrase.lower() in transcript.lower(), f'Missing customer workflow: {phrase}'

    ffprobe=shutil.which('ffprobe')
    ffmpeg=shutil.which('ffmpeg')
    assert ffprobe and ffmpeg, 'ffmpeg and ffprobe required for actual media verification'
    probe=checked([ffprobe,'-v','error','-show_format','-show_streams','-show_chapters','-of','json',str(MOVIE)])
    (out/'ffprobe.json').write_bytes(probe)
    meta=json.loads(probe)
    videos=[x for x in meta['streams'] if x['codec_type']=='video']
    audios=[x for x in meta['streams'] if x['codec_type']=='audio']
    assert len(videos)==1 and len(audios)==1, 'Training needs one video and one narration track'
    video,audio=videos[0],audios[0]
    duration=float(meta['format']['duration'])
    assert duration>=300, 'A complete guide must teach more than the short teaser'
    assert abs(duration-timeline['duration_seconds'])<0.2, 'Media/timeline duration mismatch'
    assert video['codec_name']=='h264' and audio['codec_name']=='aac', 'Use native H.264 and AAC'
    assert (int(video['width']),int(video['height']))==(1080,1920), 'Use portrait 1080p'
    assert video['pix_fmt']=='yuv420p', 'Use 8-bit 4:2:0 for broad device compatibility'
    assert abs(float(video['duration'])-float(audio['duration']))<0.25, 'Voice and pictures must stay synchronized'
    chapters=meta['chapters']
    assert [x.get('tags',{}).get('title') for x in chapters]==CHAPTERS, 'Video chapter titles mismatch'
    for chapter,expected in zip(chapters,timeline['chapters']):
        assert abs(float(chapter['start_time'])-expected['start'])<0.05, 'Chapter start out of sync'
        assert abs(float(chapter['end_time'])-expected['end'])<0.05, 'Chapter end out of sync'

    # Decode first, middle and final pictures plus speech near both ends.
    for stamp in (0,duration/2,max(0,duration-2)):
        frame=checked([ffmpeg,'-v','error','-ss',f'{stamp:.3f}','-i',str(MOVIE),
                       '-frames:v','1','-f','image2pipe','-vcodec','png','pipe:1'],timeout=40)
        assert frame.startswith(b'\x89PNG\r\n\x1a\n'), f'Frame failed at {stamp:.1f}s'
    rms=[]
    for stamp in (1,max(1,duration-10)):
        pcm=checked([ffmpeg,'-v','error','-ss',f'{stamp:.3f}','-i',str(MOVIE),
                     '-map','0:a:0','-t','3','-ar','16000','-ac','1','-f','s16le','pipe:1'],timeout=40)
        samples=array.array('h');samples.frombytes(pcm)
        assert samples, f'Voice failed to decode at {stamp:.1f}s'
        level=math.sqrt(sum(x*x for x in samples)/len(samples))
        assert level>100, f'Voice inaudible at {stamp:.1f}s (RMS {level:.1f})'
        rms.append(round(level,1))

    receipt={'passed':True,'video':str(MOVIE),'duration_seconds':duration,
             'chapters':len(chapters),'scenes':len(scenes),'bytes':MOVIE.stat().st_size,
             'video_codec':video['codec_name'],'audio_codec':audio['codec_name'],
             'width':video['width'],'height':video['height'],'pixel_format':video['pix_fmt'],
             'narration_rms_first_last':rms,'video_sha256':sha(MOVIE),
             'transcript_sha256':sha(TRANSCRIPT),
             'scope':'Local asset decodes and matches source timeline. Device playback and visual judgment are separate.'}
    if args.app_bundle:
        for asset in (MOVIE,TRANSCRIPT):
            candidates=list(args.app_bundle.rglob(asset.name))
            assert len(candidates)==1, f'Expected exactly one bundled {asset.name}'
            assert sha(candidates[0])==sha(asset), f'Bundled {asset.name} differs from reviewed source'
        receipt['app_bundle']=str(args.app_bundle)
        receipt['bundled_asset_bytes_match']=True
    (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt))


if __name__=='__main__':
    main()
