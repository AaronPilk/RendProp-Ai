import datetime
import hashlib
import io
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from PIL import Image, ImageCms
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'container'))
from prepare_image import normalize, prepare_image, MAX_OUTPUT_BYTES
from renderer import render, validate_task, upload_prepared
from http_adapter import Runtime

JOB='00000000-0000-4000-8000-000000000001'
LEASE='00000000-0000-4000-8000-000000000002'

def task(source):
 return {'action':'prepare_image','state':'preparing','job_id':JOB,'lease_token':LEASE,
         'source':{'url':'https://media.test/owned-master?signature=one','sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'bytes':source.stat().st_size,'etag':'owned'},
         'output':{'asset_id':JOB,'key':'prepared/owned.jpg'},'expires_at':(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=1)).isoformat()}

class ActualPreparation(unittest.TestCase):
 def test_4k_exif_rotated_colors_and_original_hash_unchanged(self):
  with tempfile.TemporaryDirectory() as root:
   source,target=Path(root)/'original.jpg',Path(root)/'prepared.jpg'
   image=Image.new('RGB',(4000,2000),'red');image.paste('blue',(2000,0,4000,2000));exif=Image.Exif();exif[274]=6;exif[270]='Private master metadata'
   profile=ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes();image.save(source,'JPEG',quality=100,subsampling=0,exif=exif,icc_profile=profile);original=hashlib.sha256(source.read_bytes()).hexdigest()
   facts=normalize(source,target);self.assertEqual((facts['width'],facts['height']),(1024,2048));self.assertEqual((facts['source_width'],facts['source_height']),(2000,4000));self.assertLess(target.stat().st_size,MAX_OUTPUT_BYTES)
   with Image.open(target) as result:
    result.load();self.assertEqual(result.format,'JPEG');self.assertEqual(result.getexif(),{});self.assertTrue(result.info.get('icc_profile'));top=result.getpixel((512,200));bottom=result.getpixel((512,1800));self.assertGreater(top[0],240);self.assertGreater(bottom[2],240)
   self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(),original)

 def test_actual_srgb_icc_conversion_and_alpha_and_bad_profile_refusal(self):
  with tempfile.TemporaryDirectory() as root:
   source,target=Path(root)/'lab.tif',Path(root)/'out.jpg'
   lab=ImageCms.ImageCmsProfile(ImageCms.createProfile('LAB'));srgb=ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB'))
   image=Image.new('RGB',(300,200),(50,160,220));converted=ImageCms.profileToProfile(image,srgb,lab,outputMode='LAB')
   # Actual supported WebP cannot represent LAB; use supported JPEG CMYK with
   # an ICC test double only for the unsupported-formatguard below.
   png=Path(root)/'rgb.png';image.save(png,icc_profile=srgb.tobytes());normalize(png,target)
   with Image.open(target) as result:self.assertLess(max(abs(a-b)for a,b in zip(result.getpixel((150,100)),(50,160,220))),4)
   alpha=Image.new('RGBA',(200,100),(255,0,0,0));alpha.paste((0,255,0,255),(100,0,200,100));alpha.save(png);normalize(png,target)
   with Image.open(target)as result:self.assertTrue(all(c > 240 for c in result.getpixel((25,50))));self.assertGreater(result.getpixel((175,50))[1],240)
   image.save(png,icc_profile=b'not a color profile')
   with self.assertRaises(ValueError):normalize(png,target)
   converted.save(source,icc_profile=lab.tobytes())
   with self.assertRaises(ValueError):normalize(source,target)

 def test_prepare_receipt_upload_single_exact_asset_and_interrupted_cleanup(self):
  with tempfile.TemporaryDirectory() as root:
   source=Path(root)/'original.png';Image.new('RGB',(4096,3072),(100,160,220)).save(source);value=task(source);validate_task(value)
   def owned_download(item,target,hosts,**options):
    self.assertEqual(options['max_bytes'],50*1024*1024);self.assertEqual(item['sha256'],value['source']['sha256']);shutil.copyfile(source,target);return item['sha256']
   with patch('prepare_image.download',side_effect=owned_download):prepared=render(value,{'media.test'},root)
   receipt=prepared['result']['receipt'];self.assertEqual((receipt['width'],receipt['height']),(2048,1536));self.assertEqual(receipt['source_sha256'],value['source']['sha256']);self.assertEqual(receipt['mime'],'image/jpeg');self.assertFalse((prepared['directory']/'source-master').exists())
   calls=[]
   with patch('renderer.upload',side_effect=lambda *args:calls.append(args)):
    output={'asset_id':JOB,'put_url':'https://media.test/prepared?signature=two','headers':{},'expires_at':value['expires_at']};self.assertEqual(upload_prepared(prepared,output,{'media.test'}),receipt);self.assertEqual(len(calls),1);self.assertEqual(calls[0][2],'image/jpeg')
    with self.assertRaises(ValueError):upload_prepared(prepared,{**output,'asset_id':LEASE},{'media.test'})
   shutil.rmtree(prepared['directory'])
   def interrupted(item,target,hosts,**options):Path(target).write_bytes(b'partial private bytes');raise ValueError('expired capability')
   before=set(Path(root).iterdir())
   with patch('prepare_image.download',side_effect=interrupted):
    with self.assertRaises(ValueError):render(value,{'media.test'},root)
   self.assertEqual(set(Path(root).iterdir()),before,'all partial private working bytes removed')
   runtime=Runtime('x'*40,{'media.test'},root,runner=lambda *args: {'directory':Path(tempfile.mkdtemp(dir=root)),'result':{'receipt':receipt,'prepared_image':source}})
   key=runtime.enqueue(value);runtime.future.result(3);self.assertEqual(runtime.status(key)['state'],'prepared');runtime.close()

 def test_oversized_bytes_pixels_animation_refused(self):
  with tempfile.TemporaryDirectory() as root:
   source=Path(root)/'photo.png';Image.new('RGB',(10,10)).save(source);value=task(source);value['source']['bytes']=50*1024*1024+1
   with self.assertRaises(ValueError):validate_task(value)
   with patch('prepare_image.MAX_PIXELS',99):
    with self.assertRaises(ValueError):normalize(source,Path(root)/'out.jpg')
   Image.new('RGB',(10,10)).save(source,save_all=True,append_images=[Image.new('RGB',(10,10),'red')],format='PNG')
   with self.assertRaises(ValueError):normalize(source,Path(root)/'out.jpg')
