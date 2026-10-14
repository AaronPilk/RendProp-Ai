import concurrent.futures
import datetime
import hashlib
import json
import http.client
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "container"))
from capabilities import checked_url, download
from compose import compose, MusicSource, probe, QualityError, run
from http_adapter import Runtime,make_handler
from http.server import ThreadingHTTPServer
from music_catalog import validate_music, CATALOG
from renderer import validate_task,extract

JOB="00000000-0000-4000-8000-000000000001"
LEASE="00000000-0000-4000-8000-000000000002"


def task():
    return {"action":"compose","job_id":JOB,"lease_token":LEASE,"manifest_sha256":"a"*64,
            "purpose":"listing","aspect":"16:9","sources":[{"position":0,"bytes":12,"motion_kind":"ai"}],
            "presentation":{"transition":"cut","shot_caption_style":"off","spoken_captions":False,"shot_labels":[None]},
            "output":{"asset_id":JOB,"poster_asset_id":LEASE},
            "expires_at":(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=1)).isoformat()}


class Boundaries(unittest.TestCase):
    def test_no_arbitrary_urls_or_expired_task(self):
        for url in ["http://media.test/x","https://bad.test/x","https://x@y@media.test/x","https://media.test:8443/x","https://127.0.0.1/x"]:
            with self.assertRaises(ValueError):checked_url(url,{"media.test"})
        value=task();value["expires_at"]="2000-01-01T00:00:00Z"
        with self.assertRaises(ValueError):validate_task(value)
        value=task();value["evil"]="https://attacker.test"
        with self.assertRaises(ValueError):validate_task(value)
        value=task();value["sources"][0]["position"]=9
        with self.assertRaises(ValueError):validate_task(value)

    def test_music_closed_catalog_and_off(self):
        self.assertIsNone(validate_music(None))
        for key,track in CATALOG.items():
            value={"track_id":key,**track,"license_id":"CC0-1.0","gain":.18,"duck_gain":.07}
            self.assertEqual(validate_music(value),track)
            with self.assertRaises(ValueError):validate_music({**value,"asset_sha256":"a"*64})
            with self.assertRaises(ValueError):validate_music({**value,"license_evidence_sha256":"a"*64})
        with self.assertRaises(ValueError):validate_music({"track_id":"customer_url"})

    def test_duplicate_work_single_admission_and_restart_missing(self):
        barrier=__import__('threading').Event();calls=[]
        def runner(body,hosts,root):
            calls.append(body["job_id"]);barrier.wait(3)
            return {"result":{"receipt":{"job_id":JOB}},"directory":Path(root)}
        with tempfile.TemporaryDirectory() as root:
            runtime=Runtime("x"*40,{"media.test"},root,runner=runner)
            value=task();one=runtime.enqueue(value)
            self.assertEqual(runtime.enqueue(value),one)
            other=task();other["lease_token"]="00000000-0000-4000-8000-000000000003"
            with self.assertRaises(PermissionError):runtime.enqueue(other)
            self.assertEqual(runtime.status(one)["state"],"working")
            barrier.set();runtime.future.result(3)
            self.assertEqual(runtime.status(one)["state"],"prepared")
            fresh=Runtime("y"*40,{"media.test"},root)
            self.assertEqual(fresh.status(one),{"state":"missing"})
            fresh.close();runtime.close();self.assertEqual(len(calls),1)

    def test_real_http_private_auth_and_closed_body(self):
        import threading
        runtime=Runtime('x'*40,{'media.test'})
        server=ThreadingHTTPServer(('127.0.0.1',0),make_handler(runtime))
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            conn=http.client.HTTPConnection(*server.server_address)
            conn.request('POST','/execute',body='{}',headers={'Content-Type':'application/json'})
            reply=conn.getresponse();self.assertEqual(reply.status,403);reply.read();conn.close()
            conn=http.client.HTTPConnection(*server.server_address)
            conn.request('POST','/execute',body='{}',headers={'Authorization':'Bearer '+'x'*40,'Content-Type':'application/json'})
            reply=conn.getresponse();self.assertEqual(reply.status,400);reply.read();conn.close()
            self.assertIsNone(runtime.task_id)
        finally:server.shutdown();server.server_close();runtime.close();thread.join(3)


class ActualFFmpeg(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        full=os.environ.get('RENDER_TEST_FFMPEG')
        cls.binary_patch=None
        if full:
            if not Path(full).is_file():raise ValueError('explicit test FFmpeg binary missing')
            real_which=shutil.which
            cls.binary_patch=patch('shutil.which',side_effect=lambda name:full if name=='ffmpeg' else real_which(name))
            cls.binary_patch.start()
        cls.tmp=tempfile.TemporaryDirectory();cls.root=Path(cls.tmp.name)
        for name,color,dimensions in [("red","red","1920x1080"),("blue","blue","1920x1080"),("portrait","green","1080x1920")]:
            run([shutil.which("ffmpeg"),"-hide_banner","-loglevel","error","-nostdin","-y","-f","lavfi","-i",f"color=c={color}:s={dimensions}:r=30:d=5","-an","-c:v","libx264","-preset","ultrafast","-crf","18","-threads","2",str(cls.root/f"{name}.mp4")])
        for name,freq,duration in [("music",200,3),("voice",1000,2)]:
            run([shutil.which("ffmpeg"),"-hide_banner","-loglevel","error","-nostdin","-y","-f","lavfi","-i",f"sine=frequency={freq}:duration={duration}:sample_rate=48000","-c:a","pcm_s16le",str(cls.root/f"{name}.wav")])
        cls.music=MusicSource("synthetic-proof",cls.root/"music.wav",hashlib.sha256((cls.root/"music.wav").read_bytes()).hexdigest(),"test-only","Self-generated200Hz")
        fonts=[Path('/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf'),Path('/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf'),Path('/System/Library/Fonts/Supplemental/Arial Bold.ttf')]
        cls.font=next((p for p in fonts if p.is_file()),None)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()
        if cls.binary_patch:cls.binary_patch.stop()

    def test_real1080_order_music_voice_poster_and_off(self):
        result=compose([self.root/'red.mp4',self.root/'blue.mp4'],self.root/'mix',music=self.music,narration=self.root/'voice.wav',test_fast=True)
        self.assertEqual((result['width'],result['height'],result['duration_s']),(1920,1080,10))
        self.assertTrue(result['poster'].stat().st_size>1000)
        self.assertTrue(any(s['codec_type']=='audio' for s in result['facts']['streams']))
        def volume(at,frequency):
            facts=run([shutil.which('ffmpeg'),'-hide_banner','-ss',str(at),'-t','1','-i',str(result['master']),'-vn',
                       '-af',f'bandpass=f={frequency}:width_type=h:w=20,volumedetect','-f','null','-']).stderr.decode()
            return float(re.search(r'mean_volume: ([-\d.]+) dB',facts).group(1))
        self.assertLess(volume(.5,200),volume(3.5,200)-5,'music really ducks during narration')
        self.assertGreater(volume(8,200),-70,'three-second source really loops through final video')
        self.assertGreater(volume(.5,1000),-40,'voice remains audible in actual mux')
        # Decode actual first/second scenes rather than asserting metadata only.
        for second,channel in [(1,0),(6,2)]:
            data=run([shutil.which('ffmpeg'),'-v','error','-ss',str(second),'-i',str(result['master']),'-frames:v','1','-vf','scale=1:1','-f','rawvideo','-pix_fmt','rgb24','-']).stdout
            self.assertGreater(data[channel],200)
        off=compose([self.root/'portrait.mp4'],self.root/'off',aspect='9:16',test_fast=True)
        self.assertEqual((off['width'],off['height']),(1080,1920))
        self.assertFalse(any(s['codec_type']=='audio' for s in off['facts']['streams']))
        with self.assertRaises(QualityError):compose([self.root/'portrait.mp4'],self.root/'no-upscale',aspect='16:9',test_fast=True)
        wrong=MusicSource('bad',self.music.path,'a'*64,'test','')
        with self.assertRaises(QualityError):compose([self.root/'red.mp4'],self.root/'bad-music',music=wrong,test_fast=True)

    def test_actual_three_frames_measured_clip(self):
        value={'job_id':JOB,'attempt_id':LEASE,'lease_token':LEASE,'clip':{}}
        def owned_download(item,target,hosts,hash_optional=False):
            shutil.copyfile(self.root/'red.mp4',target)
            return hashlib.sha256(Path(target).read_bytes()).hexdigest()
        with patch('renderer.download',side_effect=owned_download):
            directory=self.root/'extract';directory.mkdir()
            result=extract(value,directory,{'media.test'})
        self.assertEqual(len(result['frames']),3)
        self.assertEqual((result['width'],result['height']),(1920,1080))
        self.assertEqual(result['clip_sha256'],hashlib.sha256((self.root/'red.mp4').read_bytes()).hexdigest())
        self.assertTrue(all(frame['mime']=='image/jpeg' for frame in result['frames']))

    def test_dissolve_whip_and_every_caption_style_actual_frames(self):
        if not self.font:self.fail('caption font required for actual presentation acceptance')
        with patch.dict(os.environ,{'RENDER_FONT':str(self.font)}):
            for transition,style in [('dissolve','lowerThird'),('whip','punchCard'),('cut','highlightBox')]:
                presentation={'transition':transition,'shot_caption_style':style,'spoken_captions':True,
                              'title_card':{'title':"OPEN HOUSE: 50% [great]",'subtitle':"Real source / no injection",'watermark':'Made with Rendprop'},
                              'shot_labels':['WELCOME HOME','LIGHT FILLED KITCHEN']}
                result=compose([self.root/'red.mp4',self.root/'blue.mp4'],self.root/f'presentation-{style}',test_fast=True,presentation=presentation,
                               narration=self.root/'voice.wav',words=[{'text':"Hello: 100% 'home'",'start':.2,'end':1.2}])
                facts=result['facts'];self.assertEqual((result['width'],result['height']),(1920,1080))
                self.assertAlmostEqual(float(facts['format']['duration']),result['duration_s'],delta=.1)
                # White pixels prove text actually reached encoded frames.
                pixels=run([shutil.which('ffmpeg'),'-v','error','-ss','0.8','-i',str(result['master']),'-frames:v','1','-vf','scale=192:108','-f','rawvideo','-pix_fmt','rgb24','-']).stdout
                whites=sum(1 for i in range(0,len(pixels),3) if min(pixels[i:i+3])>180)
                self.assertGreater(whites,5)


if __name__=='__main__':unittest.main()
