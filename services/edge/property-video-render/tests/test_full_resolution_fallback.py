import hashlib
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from PIL import Image,ImageCms,ImageOps
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'container'))
from compose import run,probe
from prepare_image import normalize_full_resolution,decoded_srgb
from renderer import render
from test_cpu import task

class FullResolutionFallback(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.binary=None;full=os.environ.get('RENDER_TEST_FFMPEG')
  if full:
   actual=shutil.which;cls.binary=patch('shutil.which',side_effect=lambda name:full if name=='ffmpeg'else actual(name));cls.binary.start()
 @classmethod
 def tearDownClass(cls):
  if cls.binary:cls.binary.stop()
 def source(self,root,bad_profile=False):
  original=Path(root)/'master.jpg';image=Image.new('RGB',(4000,2000),'yellow');image.paste('red',(100,100,900,1900));image.paste('blue',(3100,100,3900,1900));exif=Image.Exif();exif[274]=6;exif[270]='private metadata'
  profile=b'invalid-profile'if bad_profile else ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes();image.save(original,quality=100,subsampling=0,exif=exif,icc_profile=profile);return original
 def test_lossless_full_resolution_copy_preserves_oriented_pixels_color_and_original(self):
  with tempfile.TemporaryDirectory() as root:
   original=self.source(root);before=original.read_bytes();target=Path(root)/'full.png';facts=normalize_full_resolution(original,target);self.assertEqual(facts,{'width':2000,'height':4000})
   decoded,_=decoded_srgb(original)
   with Image.open(target)as actual:
    actual.load();self.assertEqual(actual.getexif(),{});self.assertEqual(actual.tobytes(),decoded.tobytes(),'lossless RGB workingcopy has no second JPEG compression');self.assertGreater(actual.getpixel((1000,400))[0],240);self.assertGreater(actual.getpixel((1000,3600))[2],240)
   self.assertEqual(original.read_bytes(),before)
 def test_actual_cpu_fallback_rotated_fullmaster_fills1080_and_failure_cleans_workingcopy(self):
  with tempfile.TemporaryDirectory() as root:
   original=self.source(root);before=hashlib.sha256(original.read_bytes()).hexdigest();body=task();body['aspect']='9:16';body['purpose']='social';body['sources']=[{'position':0,'bytes':original.stat().st_size,'sha256':before,'url':'https://media.test/master?signature=one','motion_kind':'original_photo','motion':'side_glide'}]
   def owned(item,target,hosts,**kwargs):
    self.assertEqual(kwargs['max_bytes'],50*1024*1024);shutil.copyfile(original,target);return before
   with patch('renderer.download',side_effect=owned):result=render(body,{'media.test'},root)
   master=result['result']['master'];facts=probe(master);self.assertEqual((facts['streams'][0]['width'],facts['streams'][0]['height']),(1080,1920));data=run([shutil.which('ffmpeg'),'-v','error','-ss','0.1','-i',str(master),'-frames:v','1','-f','rawvideo','-pix_fmt','rgb24','-']).stdout;image=Image.frombytes('RGB',(1080,1920),data)
   self.assertGreater(image.getpixel((540,100))[0],240,'EXIF6 top stays red');self.assertGreater(image.getpixel((540,1820))[2],240,'EXIF6 bottom stays blue');self.assertFalse(list(result['directory'].glob('input-*.jpg')));self.assertFalse(list(result['directory'].glob('input-*-oriented.png')));self.assertEqual(hashlib.sha256(original.read_bytes()).hexdigest(),before)
   shutil.rmtree(result['directory']);bad=self.source(root,bad_profile=True);remaining=set(Path(root).iterdir())
   with patch('renderer.download',side_effect=owned):
    with self.assertRaises(ValueError):render(body,{'media.test'},root)
   self.assertEqual(set(Path(root).iterdir()),remaining,'failed decode/profile leaves no private work directory')
