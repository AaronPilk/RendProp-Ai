"""Closed fixed12% production geometry/codec proof. No network, VM or image build."""
import math,sys,unittest,os,tempfile
from pathlib import Path
import numpy as np
from PIL import Image
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'container'))
import photo_motion_profile as p
from tests.test_photo_motion_profile import PhotoMotionProfile as Fixture

class Geometry(unittest.TestCase):
 def test_twelve_percent_geometry_and_four_direction_bounds(self):
  for w,h,W,H in [(2250,3000,1080,1920),(3000,2250,1920,1080)]:
   bw=min(w,h*W/H);bh=bw*H/W
   for N in [48,72,96,120]:
    for motion in ['push_in','pull_back','slide_left','slide_right']:
     boxes=[p.source_box(w,h,W,H,f,N,motion)for f in range(N)]
     for f,b in enumerate(boxes):
      e=(1-math.cos(math.pi*f/(N-1)))/2
      z=1+.12*e if motion=='push_in'else 1.12-.12*e if motion=='pull_back'else 1.12
      cw,ch=bw/z,bh/z
      x=(w-cw)/2 if motion in {'push_in','pull_back'}else(w-bw)/2+(bw-cw)*(1-e if motion=='slide_left'else e)
      y=(h-ch)/2
      for actual,expected in zip(b,[x,y,x+cw,y+ch]):self.assertAlmostEqual(actual,expected,8,msg='twelve_percent_geometry '+motion)
      self.assertTrue(0<=b[0]<b[2]<=w and 0<=b[1]<b[3]<=h)
      self.assertGreaterEqual(b[2]-b[0],W);self.assertGreaterEqual(b[3]-b[1],H)
     first,last=boxes[0],boxes[-1]
     if motion=='push_in':self.assertAlmostEqual((first[2]-first[0])/(last[2]-last[0]),1.12)
     elif motion=='pull_back':self.assertAlmostEqual((last[2]-last[0])/(first[2]-first[0]),1.12)
     else:
      self.assertAlmostEqual(abs(last[0]-first[0])/(first[2]-first[0]),.12)
      self.assertTrue(last[0]<first[0]if motion=='slide_left'else last[0]>first[0])
  with self.assertRaises(Exception):p.source_box(2250,3000,1080,1920,0,48,'side_glide')

class Codec(Fixture):
 def test_four_directions_actual_two_second_pixels(self):
  original=Image.open(self.photo).convert('RGB');w,h=original.size;bw=h*9/16;bh=h
  for motion in ['push_in','pull_back','slide_left','slide_right']:
   clip=self.root/(motion+'.mp4');p.encode_photo(self.photo,clip,'9:16',48,motion)
   f=p.probe(clip);p.require_cfr24(clip,f,exact_frames={48});self.assertEqual(float(f['format']['duration']),2)
   decoded=self.decode(clip,[0,12,24,47])
   for actual,n in zip(decoded,[0,12,24,47]):
    e=(1-math.cos(math.pi*n/47))/2
    z=1+.12*e if motion=='push_in'else 1.12-.12*e if motion=='pull_back'else 1.12
    cw,ch=bw/z,bh/z;x=(w-cw)/2 if motion in {'push_in','pull_back'}else(w-bw)/2+(bw-cw)*(1-e if motion=='slide_left'else e);y=(h-ch)/2
    ref=np.asarray(original.transform((1080,1920),Image.Transform.EXTENT,(x,y,x+cw,y+ch),Image.Resampling.BICUBIC))
    mismatch=np.mean((actual.mean(axis=2)>128)!=(ref.mean(axis=2)>128));self.assertLess(mismatch,.008,'twelve_percent_codec '+motion+' '+str(n))
   self.assertEqual(self.input_sha,__import__('hashlib').sha256(self.photo.read_bytes()).hexdigest())
 def test_v2_result_echoes_ordered_motions_and_variable_frames(self):
  task=self.task((48,72));task['sources'][1]['motion']='slide_right'
  with __import__('unittest.mock',fromlist=['patch']).patch.object(p,'download',side_effect=self.download):
   result=__import__('renderer').render(task,{'media.fixture.invalid'},str(self.root))
  receipt=result['result']['receipt'];self.assertEqual(receipt['source_motions'],['push_in','slide_right']);self.assertEqual(receipt['source_frames'],[48,72]);self.assertEqual(receipt['composition_profile'],'photo-motion-v2-cfr24');self.assertEqual(receipt['duration_s'],5);p.require_cfr24(result['result']['master'],p.probe(result['result']['master']),exact_frames={120})
 def test_v1_tasks_refuse_before_runner(self):
  task=self.task();task['composition_profile']='photo-motion-v1-cfr24'
  with self.assertRaises(Exception):__import__('renderer').validate_task(task)
  from photo_motion_http_adapter import PhotoMotionRuntime
  calls=[]
  def forbidden(*args):calls.append(args);raise AssertionError('old task executed')
  runtime=PhotoMotionRuntime('closed-private-token',{'media.fixture.invalid'},str(self.root),runner=forbidden)
  try:
   with self.assertRaises(ValueError):runtime.enqueue(task)
   self.assertEqual(calls,[])
  finally:runtime.close()
