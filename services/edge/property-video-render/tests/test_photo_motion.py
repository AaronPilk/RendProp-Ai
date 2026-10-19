import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from PIL import Image,ImageChops
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'container'))
from photo_motion import motion_filter,encode_photo_motion
from compose import QualityError,probe,run,compose
from renderer import validate_task
from test_cpu import task

class ActualPhotoMotion(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.root=Path(tempfile.mkdtemp());cls.binary=None
  full=os.environ.get('RENDER_TEST_FFMPEG')
  if full:
   actual=shutil.which;cls.binary=patch('shutil.which',side_effect=lambda name:full if name=='ffmpeg'else actual(name));cls.binary.start()
  image=Image.new('RGB',(2560,1440),'yellow');image.paste('red',(650,400,1150,750));image.save(cls.root/'source.jpg',quality=100,subsampling=0)
 @classmethod
 def tearDownClass(cls):
  shutil.rmtree(cls.root)
  if cls.binary:cls.binary.stop()
 def frame(self,clip,at):
  data=run([shutil.which('ffmpeg'),'-v','error','-ss',str(at),'-i',str(clip),'-frames:v','1','-f','rawvideo','-pix_fmt','rgb24','-']).stdout
  image=Image.frombytes('RGB',(1920,1080),data);r,g,b=image.split();mask=ImageChops.multiply(r.point(lambda v:255 if v>200 else 0),g.point(lambda v:255 if v<80 else 0));return image,mask.getbbox()
 def test_actual_four_movements_different_positions_and_no_bars(self):
  positions={}
  for motion in ['fly_through','push_in','side_glide','pull_back']:
   clip=self.root/f'{motion}.mp4';encode_photo_motion(self.root/'source.jpg',clip,'16:9',motion);facts=probe(clip)
   self.assertEqual((facts['streams'][0]['width'],facts['streams'][0]['height']),(1920,1080));self.assertAlmostEqual(float(facts['format']['duration']),5,places=2)
   first,a=self.frame(clip,.03);last,b=self.frame(clip,4.9);positions[motion]=(a,b)
   for image in [first,last]:
    for xy in [(0,0),(1919,0),(0,1079),(1919,1079)]:self.assertGreater(sum(image.getpixel(xy)),350,'actual edges have source pixels, no black/blur bars')
  width=lambda box:box[2]-box[0]
  self.assertGreaterEqual(width(positions['push_in'][1])-width(positions['push_in'][0]),4)
  self.assertGreater(width(positions['pull_back'][0])-width(positions['pull_back'][1]),5)
  self.assertLess(positions['side_glide'][1][0],positions['side_glide'][0][0]-35)
  self.assertLess(abs(width(positions['side_glide'][1])-width(positions['side_glide'][0])),3)
  self.assertNotEqual(positions['fly_through'],positions['push_in'])
  self.assertEqual(len(set(positions.values())),4)
 def test_exact1080_static_control_and_low_res_refusal(self):
  image=Image.new('RGB',(1920,1080),'yellow');image.paste('red',(650,400,1150,750));image.save(self.root/'exact.jpg',quality=100,subsampling=0)
  clip=self.root/'exact.mp4';filters=encode_photo_motion(self.root/'exact.jpg',clip,'16:9','side_glide');self.assertIn("z='1'",filters)
  self.assertEqual(self.frame(clip,.03)[1],self.frame(clip,4.9)[1])
  with self.assertRaises(QualityError):motion_filter(1280,720,1920,1080,'push_in')
  with self.assertRaises(QualityError):motion_filter(1080,1920,1920,1080,'push_in')
  with self.assertRaises(QualityError):motion_filter(2560,1440,1920,1080,'customer-filter')
 def test_explicit24_adequate_photo_motion_preserves_source_and_native_bounds(self):
  source=self.root/'source.jpg';before=source.read_bytes();clip=self.root/'steady24-photo.mp4'
  encode_photo_motion(source,clip,'16:9','side_glide',fps=24);facts=probe(clip)
  video=next(s for s in facts['streams']if s['codec_type']=='video');self.assertEqual((video['avg_frame_rate'],video['nb_frames']),('24/1','120'))
  self.assertAlmostEqual(float(facts['format']['duration']),5,places=2);self.assertEqual(source.read_bytes(),before)
  self.assertNotEqual(self.frame(clip,.03)[1],self.frame(clip,4.9)[1])
  with self.assertRaisesRegex(QualityError,'original_photo_lacks_1080_pixels'):motion_filter(896,1195,1920,1080,'push_in',fps=24)
 def test_actual_listing_legitimate_captions_still_no_title_or_mark(self):
  value=task();value['presentation']={'transition':'cut','shot_caption_style':'lowerThird','shot_labels':['ACCURATE SCENE LABEL'],'spoken_captions':True,'title_card':None};validate_task(value)
  branded={**value,'presentation':{**value['presentation'],'title_card':{'title':'Agent logo','subtitle':'','watermark':'Rendprop'}}}
  with self.assertRaises(ValueError):validate_task(branded)
  fonts=[Path('/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf'),Path('/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf'),Path('/System/Library/Fonts/Supplemental/Arial Bold.ttf')];font=next((p for p in fonts if p.is_file()),None);self.assertIsNotNone(font)
  clip=self.root/'listing-label-source.mp4';encode_photo_motion(self.root/'source.jpg',clip,'16:9','push_in')
  run([shutil.which('ffmpeg'),'-v','error','-f','lavfi','-i','sine=frequency=1000:duration=2:sample_rate=48000',str(self.root/'voice.wav')])
  with patch.dict(os.environ,{'RENDER_FONT':str(font)}):
   result=compose([clip],self.root/'captioned-listing',test_fast=True,narration=self.root/'voice.wav',presentation=value['presentation'],words=[{'text':'Verified room','start':.2,'end':1.2}])
  original,_=self.frame(clip,.8);captioned,_=self.frame(result['master'],.8)
  self.assertIsNotNone(ImageChops.difference(original,captioned).getbbox(),'actual listing captions render into output pixels')
  self.assertEqual((result['width'],result['height']),(1920,1080));self.assertTrue(any(s['codec_type']=='audio'for s in result['facts']['streams']))
