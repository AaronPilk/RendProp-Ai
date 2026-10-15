import copy
import datetime
import hashlib
import http.client
import threading
import io
import json
import shutil
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch
from PIL import Image, ImageCms
from capabilities import digest
from photo_quality import (prepare_photo_quality, validate_photo_task, pixel_digest,
                           crop_rectangles, upload_photo_quality, POLICY)
from renderer import render
from http_adapter import Runtime, PrivateHTTPServer, make_handler

CHECK='00000000-0000-4000-8000-000000000001'
EVIDENCE='00000000-0000-4000-8000-000000000002'
LEASE='00000000-0000-4000-8000-000000000003'

class PhotoQualityTests(unittest.TestCase):
    def setUp(self):
        self.root=Path(tempfile.mkdtemp(prefix='photo-check-test-'))
        self.addCleanup(lambda:shutil.rmtree(self.root,ignore_errors=True))
        self.source=self.root/'original.jpg';self.candidate=self.root/'candidate.png'
        # EXIF6 rotates96x64 into64x96. Metadata is baked, never copied.
        image=Image.new('RGB',(96,64),(10,40,170));exif=Image.Exif();exif[274]=6
        image.save(self.source,'JPEG',quality=97,exif=exif)
        Image.new('RGB',(128,192),(20,50,160)).save(self.candidate,'PNG',icc_profile=ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes())
        self.files={'https://owned.example/source':self.source,'https://owned.example/candidate':self.candidate}
        def item(path,mime,url):return {'bucket':'captures','key':path.name,'etag':'"owned-etag"','sha256':digest(path),'bytes':path.stat().st_size,'mime':mime,'url':url}
        self.task={'action':'prepare_photo_quality','policy':POLICY,'check_id':CHECK,'evidence_id':EVIDENCE,'lease_token':LEASE,
                   'expires_at':(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(minutes=9)).isoformat(),
                   'prepared_source':item(self.source,'image/jpeg','https://owned.example/source'),
                   'candidate':item(self.candidate,'image/png','https://owned.example/candidate')}
        self.directory=self.root/'work';self.directory.mkdir()
    def copy_download(self,item,target,hosts,**kwargs):
        source=self.files[item['url']]
        self.assertEqual(item['sha256'],digest(source));self.assertEqual(item['bytes'],source.stat().st_size)
        shutil.copyfile(source,target);return digest(source)
    def prepare(self):
        with patch('photo_quality.download',side_effect=self.copy_download):return prepare_photo_quality(self.task,self.directory,{'owned.example'})
    def test_actual_exif_icc_paired_whole_and_quadrant_lineage(self):
        original_sha=digest(self.source);candidate_sha=digest(self.candidate)
        result=self.prepare();receipt=result['receipt'];manifest=receipt['manifest']
        self.assertEqual(set(receipt),{'check_id','evidence_id','lease_token','manifest'})
        self.assertNotIn('job_id',receipt);self.assertEqual(manifest['prepared_sha256'],original_sha)
        self.assertEqual(manifest['candidate_sha256'],candidate_sha)
        self.assertEqual(len(manifest['parents']),2);self.assertEqual(len(manifest['images']),10)
        parents={p['role']:p for p in manifest['parents']}
        self.assertEqual((parents['source']['normalized_width'],parents['source']['normalized_height']),(64,96))
        self.assertEqual((parents['candidate']['normalized_width'],parents['candidate']['normalized_height']),(128,192))
        self.assertNotEqual(parents['source']['normalized_pixel_sha256'],original_sha)
        for row in manifest['images']:
            parent=parents[row['role']];rect=crop_rectangles(parent['normalized_width'],parent['normalized_height'])[row['region']]
            self.assertEqual(row['crop'],dict(zip(('left','top','width','height'),rect)))
            target=result['photo_quality_images'][(row['role'],row['region'])]
            self.assertEqual(digest(target),row['sha256']);self.assertEqual(target.stat().st_size,row['bytes'])
            with Image.open(target) as image:
                image.load();self.assertEqual(image.format,'JPEG');self.assertEqual(image.mode,'RGB');self.assertEqual(image.size,(row['width'],row['height']))
                self.assertEqual(dict(image.getexif()),{});self.assertTrue(image.info.get('icc_profile'))
                self.assertLessEqual(image.width,rect[2]);self.assertLessEqual(image.height,rect[3])
        self.assertEqual(digest(self.source),original_sha);self.assertEqual(digest(self.candidate),candidate_sha)
        self.assertFalse((self.directory/'source-master').exists())
    def test_real_odd_quadrants_are_complete_disjoint_and_unaligned(self):
        image=Image.new('RGB',(101,67));colors={'tl':(220,0,0),'tr':(0,220,0),'bl':(0,0,220),'br':(220,220,0)}
        rects=crop_rectangles(101,67)
        for region,color in colors.items():
            x,y,w,h=rects[region];image.paste(color,(x,y,x+w,y+h))
        source=self.root/'odd.png';image.save(source)
        item={'bucket':'captures','key':'odd.png','etag':'"e"','bytes':source.stat().st_size,'sha256':digest(source),'mime':'image/png','url':'https://owned.example/source'}
        self.files['https://owned.example/source']=source;self.files['https://owned.example/candidate']=source
        self.task['prepared_source']=item;self.task['candidate']={**item,'url':'https://owned.example/candidate'}
        result=self.prepare()
        for role in ('source','candidate'):
            for region,color in colors.items():
                with Image.open(result['photo_quality_images'][(role,region)]) as image:
                    pixel=image.getpixel((image.width//2,image.height//2));self.assertLess(max(abs(a-b) for a,b in zip(pixel,color)),4)
        self.assertEqual(sum(w*h for k,(x,y,w,h) in rects.items()if k!='whole'),101*67)
    def test_4k_candidate_downsamples_only_derivatives_with_fixed_q97(self):
        Image.new('RGB',(2048,1365),(20,40,60)).save(self.source,'JPEG',quality=97)
        Image.new('RGB',(4096,2730),(20,40,60)).save(self.candidate,'PNG')
        for key,path in (('prepared_source',self.source),('candidate',self.candidate)):
            self.task[key].update(sha256=digest(path),bytes=path.stat().st_size)
        result=self.prepare()
        parent={p['role']:p for p in result['receipt']['manifest']['parents']}['candidate']
        self.assertEqual((parent['normalized_width'],parent['normalized_height']),(4096,2730))
        for row in result['receipt']['manifest']['images']:
            limit=2048 if row['region']=='whole' else 1024
            self.assertLessEqual(max(row['width'],row['height']),limit)
        with Image.open(self.candidate) as original:self.assertEqual(original.size,(4096,2730))
    def test_task_identity_bounds_and_no_video_job_accepted(self):
        for mutate in [lambda t:t.update(job_id=CHECK),lambda t:t.update(check_id='../x'),lambda t:t.update(policy='video-jpeg-v1'),
                       lambda t:t['candidate'].update(bytes=50*1024*1024+1),lambda t:t['candidate'].update(sha256='Z'*64),
                       lambda t:t.update(expires_at='2000-01-01T00:00:00Z')]:
            task=copy.deepcopy(self.task);mutate(task)
            with self.assertRaises((ValueError,TypeError)):validate_photo_task(task)
    def test_aspect_mismatch_and_invalid_icc_refuse_without_judgement(self):
        Image.new('RGB',(192,128)).save(self.candidate,'PNG')
        self.task['candidate'].update(sha256=digest(self.candidate),bytes=self.candidate.stat().st_size)
        with self.assertRaisesRegex(ValueError,'parent_aspect_conflict'):self.prepare()
        Image.new('RGB',(128,192)).save(self.candidate,'PNG',icc_profile=b'invalid')
        self.task['candidate'].update(sha256=digest(self.candidate),bytes=self.candidate.stat().st_size)
        with self.assertRaisesRegex(ValueError,'color_profile_refused'):self.prepare()
    def test_aggregate_overflow_has_no_extra_compression_or_partial_master_change(self):
        # Real high-frequency pixels exceed the agreed aggregate budget. This is
        # a check HOLD/operational refusal, never an invented visual rejection.
        image=Image.effect_noise((2048,2048),100).convert('RGB');image.save(self.source,'JPEG',quality=97,subsampling=0)
        image.save(self.candidate,'PNG')
        for key,path in (('prepared_source',self.source),('candidate',self.candidate)):
            self.task[key].update(sha256=digest(path),bytes=path.stat().st_size)
        source_sha=digest(self.source)
        with self.assertRaisesRegex(ValueError,'comparison_budget_exceeded'):self.prepare()
        self.assertEqual(digest(self.source),source_sha)
    def test_cleanup_and_private_runtime_upload_preserve_exact_ten_descriptors(self):
        result=self.prepare();prepared={'result':result,'directory':self.directory};receipt=result['receipt']
        reserved=[]
        for row in receipt['manifest']['images']:
            reserved.append({**row,'bucket':'renders','key':f"private/{row['role']}/{row['region']}.jpg",'mime':'image/jpeg',
                             'put_url':f"https://owned.example/put/{row['role']}/{row['region']}",'headers':{'content-length':str(row['bytes']),'content-type':'image/jpeg','if-none-match':'*','x-amz-meta-sha256':row['sha256']}})
        output={'check_id':CHECK,'evidence_id':EVIDENCE,'images':reserved,'expires_at':self.task['expires_at']}
        uploads=[]
        def upload(url,path,mime,hosts,headers,**kwargs):
            self.assertTrue(kwargs['allow_existing']);self.assertEqual(headers['x-amz-meta-sha256'],digest(path));uploads.append(url)
            return None if len(uploads)==1 else '"exact-upload"'
        with patch('photo_quality.upload',side_effect=upload):actual=upload_photo_quality(prepared,output,{'owned.example'})
        self.assertEqual(len(uploads),10);self.assertEqual(len(actual['receipts']),10)
        self.assertNotIn('etag',actual['receipts'][0]);self.assertEqual(actual['receipts'][1]['etag'],'"exact-upload"')
        self.assertTrue(all('crop'in x and 'mime'in x and 'put_url'not in x and 'headers'not in x for x in actual['receipts']))
        runtime=Runtime('x'*64,{'owned.example'},str(self.root),runner=lambda t,h,r:prepared,uploader=lambda p,o,h:actual)
        task_id=runtime.enqueue(self.task)
        for _ in range(100):
            status=runtime.status(task_id)
            if status['state']!='working':break
            time.sleep(.01)
        self.assertEqual(status['state'],'prepared');self.assertEqual(status['result'],receipt)
        runtime.start_upload(task_id,output)
        for _ in range(100):
            status=runtime.status(task_id)
            if status['state']!='working':break
            time.sleep(.01)
        self.assertEqual(status['state'],'uploaded');self.assertEqual(status['result'],actual)
        runtime.close();self.assertFalse(self.directory.exists())
    def test_actual_private_http_photo_encode_and_reserved_upload(self):
        token='synthetic-test-token-'*4
        runtime=Runtime(token,{'owned.example'},str(self.root))
        server=PrivateHTTPServer(('127.0.0.1',0),make_handler(runtime))
        worker=threading.Thread(target=server.serve_forever,daemon=True);worker.start()
        def request(path,body,auth=True):
            connection=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=15)
            payload=json.dumps(body)
            connection.request('POST',path,payload,{'Content-Type':'application/json',**({'Authorization':'Bearer '+token}if auth else{})})
            response=connection.getresponse();data=json.loads(response.read());status=response.status;connection.close();return status,data
        def wait_for(terminal,task_id):
            deadline=time.monotonic()+10
            while time.monotonic()<deadline:
                status,value=request('/status',{'task_id':task_id});self.assertEqual(status,200)
                if value['state']!='working':self.assertEqual(value['state'],terminal);return value['result']
                time.sleep(.02)
            self.fail('private asynchronous photo task did not complete')
        uploaded=[]
        def put(url,path,mime,hosts,headers,**kwargs):
            self.assertTrue(kwargs['allow_existing']);self.assertEqual(digest(path),headers['x-amz-meta-sha256']);uploaded.append(url);return '\"immutable\"'
        try:
            self.assertEqual(request('/execute',self.task,False)[0],403)
            with patch('photo_quality.download',side_effect=self.copy_download),patch('photo_quality.upload',side_effect=put):
                status,value=request('/execute',self.task);self.assertEqual(status,202);task_id=value['task_id']
                prepared=wait_for('prepared',task_id);self.assertEqual(prepared['check_id'],CHECK);self.assertNotIn('job_id',prepared)
                reserved=[]
                for row in prepared['manifest']['images']:
                    reserved.append({**row,'bucket':'renders','key':f"checks/{row['role']}/{row['region']}.jpg",'mime':'image/jpeg',
                                     'put_url':f"https://owned.example/put/{row['role']}/{row['region']}",
                                     'headers':{'content-length':str(row['bytes']),'content-type':'image/jpeg','if-none-match':'*','x-amz-meta-sha256':row['sha256']}})
                output={'check_id':CHECK,'evidence_id':EVIDENCE,'expires_at':self.task['expires_at'],'images':reserved}
                self.assertEqual(request('/upload',{'task_id':task_id,'output':output})[0],202)
                complete=wait_for('uploaded',task_id);self.assertEqual(len(complete['receipts']),10);self.assertEqual(len(uploaded),10)
                self.assertTrue(all(set(x)=={'role','region','sha256','bytes','width','height','crop','mime','bucket','key','etag'}for x in complete['receipts']))
                self.assertEqual(request('/discard',{'task_id':task_id})[0],200)
        finally:
            server.shutdown();server.server_close();runtime.close();worker.join(timeout=2)

    def test_failed_decode_render_cleans_capability_work_directory(self):
        before=set(self.root.iterdir())
        with patch('photo_quality.download',side_effect=ValueError('media_hash_conflict')):
            with self.assertRaisesRegex(ValueError,'media_hash_conflict'):render(self.task,{'owned.example'},str(self.root))
        self.assertEqual(set(self.root.iterdir()),before)

if __name__=='__main__':unittest.main()
