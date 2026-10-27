"""Actual profile bodies/codecs; generated fixtures, no external media or APIs."""
import copy
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'container'))
import photo_motion_profile as p
import renderer
from photo_motion_http_adapter import PhotoMotionRuntime, deadline_seconds
from compose import QualityError, MusicSource, probe


def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class PhotoMotionProfile(unittest.TestCase):
    def setUp(self):
        proof = os.environ.get('PHOTO_MOTION_PROOF_DIR')
        self.tmp = None if proof else tempfile.TemporaryDirectory()
        self.root = Path(tempfile.mkdtemp(prefix=self._testMethodName+'-',dir=proof)) if proof else Path(self.tmp.name)
        self.photo = self.root/'master.png'
        y, x = np.indices((3000, 2250))
        gray = np.where(((x//73 + y//91) % 2)==0, 24, 232).astype(np.uint8)
        image = Image.fromarray(np.repeat(gray[:, :, None], 3, axis=2))
        ImageDraw.Draw(image).rectangle((250, 300, 610, 900), fill=(255, 255, 255))
        image.save(self.photo)
        self.input_sha = sha(self.photo)
        self.producer = {'image_uri':'registry.cloudflare.com/9c332c75b96cc642621dad5d86d4bf18/rendprop-property-video-photo-motion@sha256:'+'d'*64,
                         'controller_sha256':'a'*64,'renderer_source_sha256':sha(p.__file__)}
        self.producer_env=patch.dict(os.environ,{'PHOTO_MOTION_PRODUCER_IDENTITY':json.dumps(self.producer)})
        self.producer_env.start()

    def tearDown(self):
        self.producer_env.stop()
        if self.tmp:self.tmp.cleanup()

    def task(self, frames=(48,)):
        return {'state':'composing','action':'compose','source_mode':p.MODE,'composition_profile':p.PROFILE,
                'job_id':'11111111-1111-4111-8111-111111111111','lease_token':'22222222-2222-4222-8222-222222222222',
                'manifest_sha256':'b'*64,'producer_identity':copy.deepcopy(self.producer),'purpose':'social','aspect':'9:16',
                'sources':[{'url':'https://media.fixture.invalid/master','sha256':self.input_sha,'bytes':self.photo.stat().st_size,'etag':'"fixture"',
                            'position':i,'motion_kind':'photo_motion','motion':'push_in','visible_frames':n}for i,n in enumerate(frames)],
                'presentation':{'transition':'cut','shot_caption_style':'off','spoken_captions':False,'shot_labels':[]},
                'narration':None,'music':None,'output':{'asset_id':'33333333-3333-4333-8333-333333333333','key':'fixture/master',
                  'poster_asset_id':'44444444-4444-4444-8444-444444444444','poster_key':'fixture/poster'},
                'expires_at':(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(minutes=10)).isoformat()}

    def download(self, source, target, hosts, **_):
        self.assertEqual(hosts, {'media.fixture.invalid'})
        self.assertEqual(source['url'], 'https://media.fixture.invalid/master')
        self.assertEqual(source['bytes'], self.photo.stat().st_size)
        self.assertEqual(source['sha256'], self.input_sha)
        shutil.copyfile(self.photo, target)
        return sha(target)

    def decode(self, clip, indices):
        expression = '+'.join(f'eq(n\\,{n})'for n in indices)
        out = subprocess.check_output(['ffmpeg','-v','error','-nostdin','-protocol_whitelist','file,pipe','-i',str(clip),
            '-vf','select='+expression,'-fps_mode','passthrough','-f','rawvideo','-pix_fmt','rgb24','-'])
        return np.frombuffer(out,np.uint8).reshape(len(indices),1920,1080,3)

    def test_producer_requires_actual_image_controller_and_self_source(self):
        task=self.task();renderer.validate_task(task)
        for key,value in [('image_uri','foreign'),('controller_sha256','f'*64),('renderer_source_sha256','f'*64)]:
            changed=copy.deepcopy(task);changed['producer_identity'][key]=value
            with self.assertRaisesRegex(QualityError,'producer_conflict'):renderer.validate_task(changed)
        foreign=copy.deepcopy(self.producer);foreign['renderer_source_sha256']='f'*64
        task['producer_identity']=foreign
        with patch.dict(os.environ,{'PHOTO_MOTION_PRODUCER_IDENTITY':json.dumps(foreign)}):
            with self.assertRaisesRegex(QualityError,'producer_conflict'):renderer.validate_task(task)
        with patch.dict(os.environ,{'PHOTO_MOTION_PRODUCER_IDENTITY':''}):
            with self.assertRaisesRegex(QualityError,'producer_required'):renderer.validate_task(self.task())

    def test_actual_two_second_pixels_cadence_and_source_unchanged(self):
        clip=self.root/'actual.mp4';p.encode_photo(self.photo,clip,'9:16',48)
        facts=probe(clip);p.require_cfr24(clip,facts,exact_frames={48})
        self.assertEqual(float(facts['format']['duration']),2)
        self.assertEqual(sha(self.photo),self.input_sha)
        decoded=self.decode(clip,[0,12,24,47])
        original=Image.open(self.photo).convert('RGB')
        # Independent spatial reference: quarter-time samples witness easing,
        # fractional centered crop and no added/removed property content.
        for actual,n in zip(decoded,[0,12,24,47]):
            z=1.06-.06*math.cos(math.pi*n/47)
            h=3000/z;w=h*9/16;box=((2250-w)/2,(3000-h)/2,(2250+w)/2,(3000+h)/2)
            reference=np.asarray(original.transform((1080,1920),Image.Transform.EXTENT,box,Image.Resampling.BICUBIC))
            mismatch=np.mean((actual.mean(axis=2)>128)!=(reference.mean(axis=2)>128))
            self.assertLess(mismatch,.008,f'fractional photo fidelity frame{n}: {mismatch}')
        v=next(v for v in facts['streams']if v['codec_type']=='video')
        self.assertEqual((v['color_primaries'],v['color_transfer'],v['color_space']),('bt709','bt709','bt709'))

    def test_actual_three_four_five_seconds_both_canvases(self):
        for frames,aspect in [(72,'9:16'),(96,'16:9'),(120,'16:9')]:
            photo=self.photo
            if aspect=='16:9':
                photo=self.root/'landscape.png';Image.open(self.photo).transpose(Image.Transpose.ROTATE_90).save(photo)
            clip=self.root/f'{frames}.mp4';p.encode_photo(photo,clip,aspect,frames)
            facts=probe(clip);p.require_cfr24(clip,facts,exact_frames={frames})
            self.assertEqual(float(facts['format']['duration']),frames/24)

    def test_actual_renderer_mixed_duration_receipt_and_cut(self):
        task=self.task((48,72));renderer.validate_task(task)
        with patch.object(p,'download',side_effect=self.download):
            result=renderer.render(task,{'media.fixture.invalid'},str(self.root))
        receipt=result['result']['receipt']
        self.assertEqual(receipt['source_frames'],[48,72]);self.assertEqual(receipt['total_frames'],120)
        self.assertEqual(receipt['duration_s'],5);self.assertEqual(receipt['source_sha256s'],[self.input_sha]*2)
        self.assertEqual(receipt['source_mode'],p.MODE);self.assertEqual(receipt['composition_profile'],p.PROFILE)
        p.require_cfr24(result['result']['master'],probe(result['result']['master']),exact_frames={120})
        self.assertEqual(sha(self.photo),self.input_sha)

    def test_closed_task_and_frame_controls(self):
        original=self.task()
        variants=[]
        for field,value in [('source_mode','legacy'),('composition_profile','steady-v2-cfr24'),('action','extract_frames'),('aspect','16:9'),('extra','reject')]:
            x=copy.deepcopy(original);x[field]=value;variants.append(x)
        for field,value in [('visible_frames',49),('visible_frames',True),('motion_kind','ai'),('motion','side_glide'),('position',1),('etag',''),('bytes',True),('sha256','x'*64),('arbitrary','x')]:
            x=copy.deepcopy(original);x['sources'][0][field]=value;variants.append(x)
        for transition in ['dissolve','whip',None]:
            x=copy.deepcopy(original);x['presentation']['transition']=transition;variants.append(x)
        x=copy.deepcopy(original);x['presentation']['shot_caption_style']='unknown';variants.append(x)
        for x in variants:
            with self.subTest(x=x),self.assertRaises((QualityError,ValueError,KeyError)):renderer.validate_task(x)
        for frames in [0,47,49,121,True]:
            with self.assertRaises(QualityError):p.source_box(2250,3000,1080,1920,0,frames)
        with self.assertRaises(QualityError):p.source_box(1080,1920,1080,1920,47,48)

    def test_no_voice_tail_extension_and_exact_music_timeline(self):
        clip=self.root/'visual.mp4';p.encode_photo(self.photo,clip,'9:16',48)
        long=self.root/'long.m4a';short=self.root/'short.m4a';music=self.root/'music.m4a'
        for path,seconds in [(long,3),(short,.6),(music,.4)]:
            subprocess.run(['ffmpeg','-v','error','-nostdin','-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t',str(seconds),'-c:a','aac',str(path)],check=True)
        with self.assertRaisesRegex(QualityError,'narration_exceeds_photo_timeline'):p.mux_audio(clip,self.root/'refused.mp4',2,long)
        track=MusicSource('closed-fixture',music,sha(music),'CC0-1.0','synthetic audio fixture, not catalog acceptance')
        master=self.root/'audio.mp4';p.mux_audio(clip,master,2,short,track)
        facts=probe(master);p.require_cfr24(master,facts,exact_frames={48})
        self.assertEqual(float(facts['format']['duration']),2)
        self.assertEqual(len([s for s in facts['streams']if s['codec_type']=='audio']),1)

    def test_image_entrypoint_refuses_AI_before_any_runner(self):
        called=[]
        def forbidden_runner(*_):called.append(True);raise AssertionError('AI task reached the new image runner')
        runtime=PhotoMotionRuntime('closed-private-token',{'media.fixture.invalid'},str(self.root),runner=forbidden_runner)
        try:
            # A fully valid legacy AI task witnesses the independent image
            # boundary, rather than relying on the new profile's validation.
            legacy=self.task();legacy.pop('source_mode');legacy.pop('producer_identity');legacy['composition_profile']='steady-v2-cfr24'
            legacy['sources'][0].pop('visible_frames');legacy['sources'][0]['motion_kind']='ai'
            with self.assertRaisesRegex(ValueError,'photo_motion_only_image'):runtime.enqueue(legacy)
            for action in ['extract_frames','prepare_image','prepare_photo_quality']:
                task=self.task();task['action']=action
                with self.assertRaisesRegex(ValueError,'photo_motion_only_image'):runtime.enqueue(task)
            for field in ['source_mode','composition_profile']:
                task=self.task();task[field]='foreign'
                with self.assertRaisesRegex(ValueError,'photo_motion_only_image'):runtime.enqueue(task)
            self.assertEqual(called,[])
        finally:runtime.close()

    def test_actual_newmode_audio_preflight_and_manifest(self):
        audio=self.root/'voice.m4a'
        subprocess.run(['ffmpeg','-v','error','-nostdin','-f','lavfi','-i','sine=frequency=880:sample_rate=48000','-t','0.5','-c:a','aac',str(audio)],check=True)
        task=self.task()
        for key in ['purpose','aspect','sources','presentation','narration','music','output']:task.pop(key)
        task.update(action='inspect_audio',max_duration_s=2,source={'url':'https://media.fixture.invalid/voice','sha256':sha(audio),'bytes':audio.stat().st_size,'etag':'"voice"'})
        def local_download(source,target,hosts,**_):
            self.assertEqual(source,task['source']);self.assertEqual(hosts,{'media.fixture.invalid'});shutil.copyfile(audio,target);return sha(target)
        with patch.object(renderer,'download',side_effect=local_download):out=renderer.render(task,{'media.fixture.invalid'},str(self.root))
        measured=out['result'];self.assertEqual(measured['source_mode'],p.MODE);self.assertEqual(measured['composition_profile'],p.PROFILE)
        self.assertEqual(measured['manifest_sha256'],task['manifest_sha256']);self.assertEqual(measured['source_sha256'],sha(audio));self.assertEqual(measured['audio_streams'],1)
        self.assertLess(measured['duration_s'],2)
        task['max_duration_s']=True
        with self.assertRaises(QualityError):renderer.validate_task(task)

    def test_absolute_watchdog_input_and_real_process_exit(self):
        self.assertEqual(deadline_seconds('1210000',10000),1200)
        for raw,now in [('',0),('1',2),('1200001',0),('NaN',0),('1',float('nan')),('1'*17,0)]:
            with self.assertRaises(ValueError):deadline_seconds(raw,now)
        code="import time;from photo_motion_http_adapter import arm_deadline;arm_deadline(str(int(time.time()*1000)+100));time.sleep(5)"
        child=subprocess.run([sys.executable,'-c',code],env={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'PYTHONPATH':str(Path(p.__file__).parent)},capture_output=True,timeout=3)
        self.assertEqual(child.returncode,124)


if __name__=='__main__':unittest.main()
