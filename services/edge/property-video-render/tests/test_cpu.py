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
from http_adapter import Runtime,make_handler,PrivateHTTPServer
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

    def test_private_server_does_not_resolve_container_display_hostname(self):
        runtime=Runtime('x'*40,{'media.test'})
        error=UnicodeEncodeError('idna','a'*64,0,64,'label too long')
        with patch('socket.getfqdn',side_effect=error) as dns:
            with self.assertRaises(UnicodeEncodeError):
                ThreadingHTTPServer(('127.0.0.1',0),make_handler(runtime))
            dns.reset_mock()
            server=PrivateHTTPServer(('127.0.0.1',0),make_handler(runtime))
            try:
                self.assertEqual(server.server_name,'private-renderer')
                self.assertGreater(server.server_port,0)
                dns.assert_not_called()
            finally:server.server_close();runtime.close()

    def test_real_http_private_auth_and_closed_body(self):
        import threading
        runtime=Runtime('x'*40,{'media.test'})
        server=PrivateHTTPServer(('127.0.0.1',0),make_handler(runtime))
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

    def test_private_http_to_actual1080_master_when_hostname_dns_would_fail(self):
        import threading
        root=self.root/'http-master';root.mkdir()
        runtime=Runtime('x'*40,{'media.test'},root)
        error=UnicodeEncodeError('idna','a'*64,0,64,'label too long')
        with patch('socket.getfqdn',side_effect=error):
            server=PrivateHTTPServer(('127.0.0.1',0),make_handler(runtime))
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        clip=self.root/'red.mp4';value=task();value['sources'][0].update(url='https://media.test/owned',bytes=clip.stat().st_size,sha256=hashlib.sha256(clip.read_bytes()).hexdigest())
        def owned_download(item,target,hosts,**options):
            self.assertEqual(item['url'],'https://media.test/owned');shutil.copyfile(clip,target);return item['sha256']
        def post(path,body):
            conn=http.client.HTTPConnection(*server.server_address,timeout=10)
            try:
                conn.request('POST',path,body=json.dumps(body),headers={'Authorization':'Bearer '+'x'*40,'Content-Type':'application/json'})
                response=conn.getresponse();return response.status,json.loads(response.read())
            finally:conn.close()
        try:
            with patch('renderer.download',side_effect=owned_download):
                status,reply=post('/execute',value);self.assertEqual(status,202)
                deadline=time.monotonic()+60
                while time.monotonic()<deadline:
                    status,result=post('/status',{'task_id':reply['task_id']});self.assertEqual(status,200)
                    if result['state']!='working':break
                    time.sleep(.05)
                self.assertEqual(result['state'],'prepared')
                self.assertEqual((result['result']['width'],result['result']['height']),(1920,1080))
                self.assertAlmostEqual(result['result']['duration_s'],5,delta=.05)
                self.assertGreater(result['result']['bytes'],1000)
                self.assertEqual(result['result']['job_id'],JOB)
                self.assertEqual(result['result']['lease_token'],LEASE)
        finally:server.shutdown();server.server_close();runtime.close();thread.join(3)

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


class SteadyCadence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory();cls.root=Path(cls.tmp.name)
        for offset in [0,128]:
            # Synthetic eight-bit frame numbers. Enlarging this generated test
            # pattern is not a claim about customer source detail.
            pattern=f"geq=lum='if(gt(bitand(N+{offset},pow(2,floor(X/24))),0),235,16)':cb=128:cr=128,scale=1920:1080:flags=neighbor"
            run([shutil.which('ffmpeg'),'-v','error','-f','lavfi','-i','nullsrc=s=192x108:r=24:d=5',
                 '-vf',pattern,'-frames:v','120','-an','-c:v','libx264','-preset','ultrafast','-threads','2',str(cls.root/f'numbered-{offset}.mp4')])
        for aspect,size in [('landscape','1920x1080'),('portrait','1080x1920')]:
            run([shutil.which('ffmpeg'),'-v','error','-f','lavfi','-i',f'color=c=blue:s={size}:r=24:d=5',
                 '-an','-c:v','libx264','-preset','ultrafast','-threads','2',str(cls.root/f'{aspect}.mp4')])
        run([shutil.which('ffmpeg'),'-v','error','-i',str(cls.root/'landscape.mp4'),'-vf','fps=30',
             '-c:v','libx264','-preset','ultrafast','-threads','2',str(cls.root/'native30.mp4')])
        for name,hz,seconds in [('music',200,3),('voice',1000,2)]:
            run([shutil.which('ffmpeg'),'-v','error','-f','lavfi','-i',f'sine=frequency={hz}:duration={seconds}:sample_rate=48000',str(cls.root/f'{name}.wav')])
        cls.music=MusicSource('synthetic',cls.root/'music.wav',hashlib.sha256((cls.root/'music.wav').read_bytes()).hexdigest(),'test-only','Synthetic')

    @classmethod
    def tearDownClass(cls):cls.tmp.cleanup()

    def measured(self,result,frames):
        from compose import require_cfr24
        require_cfr24(result['master'],result['facts'],exact_frames={frames})
        self.assertEqual(next(s for s in result['facts']['streams']if s['codec_type']=='video')['avg_frame_rate'],'24/1')
        print('STEADY_V2_ACTUAL '+json.dumps({'width':result['width'],'height':result['height'],'duration_s':result['duration_s'],'frames':frames,'fps':24,'audio':any(s['codec_type']=='audio'for s in result['facts']['streams'])}))
        run([shutil.which('ffmpeg'),'-v','error','-nostdin','-xerror','-err_detect','explode','-i',str(result['master']),'-f','null','-'])

    def frame_numbers(self,path):
        raw=run([shutil.which('ffmpeg'),'-v','error','-i',str(path),'-vf','scale=8:1:flags=neighbor,format=gray',
                 '-fps_mode','passthrough','-f','rawvideo','-']).stdout
        self.assertEqual(len(raw)%8,0)
        return [sum((1<<j)for j,value in enumerate(raw[i:i+8])if value>128)for i in range(0,len(raw),8)]

    def test_actual_numbered24_frames_once_and_v1_thirty_unchanged(self):
        clips=[self.root/'numbered-0.mp4',self.root/'numbered-128.mp4']
        before=[hashlib.sha256(c.read_bytes()).hexdigest()for c in clips]
        result=compose(clips,self.root/'numbered24',composition_profile='steady-v2-cfr24',test_fast=True)
        self.measured(result,240)
        expected=list(range(120))+list(range(128,248))
        self.assertEqual(self.frame_numbers(result['master']),expected,'Every native24frame must survive once; no periodic duplication')
        legacy=compose(clips,self.root/'legacy30',test_fast=True)
        self.assertEqual(next(s for s in legacy['facts']['streams']if s['codec_type']=='video')['avg_frame_rate'],'30/1')
        old=self.frame_numbers(legacy['master']);self.assertEqual(len(old),300);self.assertEqual(len(old)-len(set(old)),60)
        self.assertEqual([hashlib.sha256(c.read_bytes()).hexdigest()for c in clips],before)

    def test_actual24_transitions_caption_pixels_music_voice_and_canvases(self):
        fonts=[Path('/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf'),Path('/System/Library/Fonts/Supplemental/Arial Bold.ttf')]
        font=next((p for p in fonts if p.is_file()),None);self.assertIsNotNone(font)
        for aspect,file in [('16:9','landscape'),('9:16','portrait')]:
            for transition,overlap in [('cut',0),('dissolve',6),('whip',4)]:
                source=self.root/f'{file}.mp4';directory=self.root/f'{file}-{transition}'
                presentation={'transition':transition,'shot_caption_style':'lowerThird','spoken_captions':True,'shot_labels':['ROOM ONE','ROOM TWO']}
                with patch.dict(os.environ,{'RENDER_FONT':str(font)}):
                    result=compose([source,source],directory,aspect=aspect,narration=self.root/'voice.wav',music=self.music,
                                   presentation=presentation,words=[{'text':'Verified room','start':.2,'end':1.2}],test_fast=True,composition_profile='steady-v2-cfr24')
                self.measured(result,240-overlap)
                self.assertAlmostEqual(result['duration_s'],(240-overlap)/24,places=6)
                self.assertEqual((result['width'],result['height']),(1920,1080)if aspect=='16:9'else(1080,1920))
                pixels=run([shutil.which('ffmpeg'),'-v','error','-ss','0.8','-i',str(result['master']),'-frames:v','1','-vf','scale=192:108','-f','rawvideo','-pix_fmt','rgb24','-']).stdout
                self.assertGreater(sum(min(pixels[i:i+3])>180 for i in range(0,len(pixels),3)),5,'Text must reach actual pixels')
                def volume(at,hz):
                    log=run([shutil.which('ffmpeg'),'-hide_banner','-ss',str(at),'-t','0.5','-i',str(result['master']),'-vn',
                             '-af',f'bandpass=f={hz}:width_type=h:w=20,volumedetect','-f','null','-']).stderr.decode()
                    return float(re.search(r'mean_volume: ([-\d.]+) dB',log).group(1))
                self.assertGreater(volume(.5,1000),-40)
                self.assertLess(volume(.5,200),volume(3.5,200)-5)
                self.assertGreater(volume(result['duration_s']-.7,200),-70)

    def test_native121st_endpoint_sample_trims_only_outside_five_second_window(self):
        source=self.root/'numbered121.mp4'
        pattern="geq=lum='if(gt(bitand(N,pow(2,floor(X/24))),0),235,16)':cb=128:cr=128,scale=1920:1080:flags=neighbor"
        run([shutil.which('ffmpeg'),'-v','error','-f','lavfi','-i','nullsrc=s=192x108:r=24:d=5.05',
             '-vf',pattern,'-frames:v','121','-an','-c:v','libx264','-preset','ultrafast','-threads','2',str(source)])
        before=hashlib.sha256(source.read_bytes()).hexdigest()
        result=compose([source],self.root/'endpoint24',composition_profile='steady-v2-cfr24',test_fast=True)
        self.measured(result,120)
        self.assertEqual(self.frame_numbers(result['master']),list(range(120)))
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(),before)

    def test_transition_boundaries_keep_exact_real_bodies_and_bounded_bridge(self):
        from presentation import timeline
        from compose import require_cfr24
        sources=[self.root/'numbered-0.mp4',self.root/'numbered-128.mp4']
        before=[hashlib.sha256(p.read_bytes()).hexdigest()for p in sources]
        for name,frames in [('dissolve',6),('whip',4)]:
            directory=self.root/('boundary-'+name);directory.mkdir()
            parts,duration,_=timeline(sources,directory,name,fps=24)
            self.assertEqual(len(parts),3);self.assertEqual(duration,(240-frames)/24)
            self.assertEqual(self.frame_numbers(parts[0]),list(range(120-frames)))
            self.assertEqual(self.frame_numbers(parts[2]),list(range(128+frames,248)))
            require_cfr24(parts[1],probe(parts[1]),exact_frames={frames})
            self.assertEqual(self.frame_numbers(parts[1])[0],120-frames)
            raw=run([shutil.which('ffmpeg'),'-v','error','-i',str(parts[1]),'-vf','scale=256:144,format=gray',
                     '-fps_mode','passthrough','-f','rawvideo','-']).stdout
            size=256*144;self.assertEqual(len(raw),size*frames)
            self.assertEqual(len({hashlib.sha256(raw[i:i+size]).digest()for i in range(0,len(raw),size)}),frames,
                             'The EOF look-ahead must not add a repeated encoded transition frame')
        self.assertEqual([hashlib.sha256(p.read_bytes()).hexdigest()for p in sources],before)

    def test_mixed_or_variable_cadence_and_forged_profiles_refuse(self):
        from compose import require_cfr24
        with self.assertRaisesRegex(QualityError,'steady_v2_requires_native_cfr24'):
            compose([self.root/'landscape.mp4',self.root/'native30.mp4'],self.root/'mixed',composition_profile='steady-v2-cfr24',test_fast=True)
        with self.assertRaisesRegex(QualityError,'unsupported_composition_profile'):
            compose([self.root/'landscape.mp4'],self.root/'fake',composition_profile='customer24',test_fast=True)
        facts=probe(self.root/'landscape.mp4')
        real=run
        for points in [[0,1000,1000],[0,1000,3000]]:
            packets={'packets':[{'pts':v,'duration':1000}for v in points]}
            altered=json.loads(json.dumps(facts));altered['streams'][0]['time_base']='1/24000'
            with patch('compose.run',return_value=subprocess.CompletedProcess([],0,json.dumps(packets).encode(),b'')):
                with self.assertRaisesRegex(QualityError,'steady_v2_requires_native_cfr24'):
                    require_cfr24(self.root/'landscape.mp4',altered)
        value=task();value['composition_profile']='steady-v2-cfr24';validate_task(value)
        for wrong in [24,30,True,'fal-kling3-4k-v1','customer24']:
            with self.assertRaises(QualityError):validate_task({**value,'composition_profile':wrong})


if __name__=='__main__':unittest.main()
