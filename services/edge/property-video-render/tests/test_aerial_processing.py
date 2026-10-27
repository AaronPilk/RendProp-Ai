"""Synthetic actual preparation/qualification bodies; no network or user media."""
import copy,hashlib,json,os,shutil,subprocess,sys,unittest
from pathlib import Path
from unittest.mock import patch
from PIL import Image,ImageCms
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'container'))
import aerial_processing as a
import renderer
from compose import QualityError,probe,require_cfr24
from tests import test_photo_motion_profile as fixture
class Processing(unittest.TestCase):
 setUp=fixture.PhotoMotionProfile.setUp
 tearDown=fixture.PhotoMotionProfile.tearDown
 def task(self,prepare=True):
  t=fixture.PhotoMotionProfile.task(self)
  for key in ['purpose','aspect','sources','presentation','narration','music','output']:t.pop(key)
  t.update(state='preparing'if prepare else'qualifying',action='prepare_image'if prepare else'compose',composition_profile=a.INPUT_PROFILE if prepare else a.QUALIFY_PROFILE,aspect='16:9',output={'asset_id':'33333333-3333-4333-8333-333333333333','key':'aerial/input'})
  if prepare:t.update(source={'url':'https://media.fixture.invalid/original','sha256':self.input_sha,'bytes':self.photo.stat().st_size,'etag':'original'},reviewed_crop={'x':0,'y':0,'width':1920,'height':1080,'source_width':2250,'source_height':3000})
  else:t.update(clip={'url':'https://media.fixture.invalid/clip','sha256':'a'*64,'bytes':1,'etag':'clip'},source_sha256='f'*64);t['output'].update(poster_asset_id='44444444-4444-4444-8444-444444444444',poster_key='aerial/poster')
  return t
 def local_read(self,source):
  def read(media,target,hosts,**kw):
   self.assertEqual(hosts,{'media.fixture.invalid'});self.assertEqual(media['sha256'],hashlib.sha256(source.read_bytes()).hexdigest());self.assertEqual(media['bytes'],source.stat().st_size);shutil.copyfile(source,target);return media['sha256']
  return read
 def test_actual_oriented_reviewed_crop_full_source_immutable(self):
  source=self.root/'original-disguised.jpg';im=Image.new('RGB',(4032,3024),(180,60,30));exif=Image.Exif();exif[274]=6;exif[34853]={};icc=ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes();im.save(source,'JPEG',quality=97,exif=exif,icc_profile=icc);sha=hashlib.sha256(source.read_bytes()).hexdigest()
  t=self.task();t.update(aspect='9:16',reviewed_crop={'x':400,'y':96,'width':2160,'height':3840,'source_width':3024,'source_height':4032});t['source'].update(sha256=sha,bytes=source.stat().st_size)
  with patch.object(a,'download',side_effect=self.local_read(source)):out=renderer.render(t,{'media.fixture.invalid'},str(self.root))['result']
  r=out['receipt'];self.assertEqual((r['width'],r['height']),(1152,2048));self.assertEqual(r['reviewed_crop'],t['reviewed_crop']);self.assertEqual(r['source_sha256'],sha)
  with Image.open(out['prepared_image'])as check:self.assertEqual(check.format,'JPEG');self.assertFalse(check.getexif());self.assertTrue(check.info['icc_profile']);self.assertEqual(check.size,(1152,2048))
  self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(),sha)
 def test_closed_crop_no_upscale_and_actual_raster_conflict(self):
  t=self.task();renderer.validate_task(t)
  for c in [{**t['reviewed_crop'],'x':1000},{**t['reviewed_crop'],'width':1919},{**t['reviewed_crop'],'height':720},{**t['reviewed_crop'],'source_width':True},{**t['reviewed_crop'],'extra':0}]:
   with self.assertRaises((QualityError,ValueError)):renderer.validate_task({**t,'reviewed_crop':c})
  t['reviewed_crop']['source_width']=3000
  with patch.object(a,'download',side_effect=self.local_read(self.photo)),self.assertRaisesRegex(QualityError,'oriented_source_changed'):renderer.render(t,{'media.fixture.invalid'},str(self.root))
 def test_heif_missing_decoder_and_no_hdr_or_unknown_color_claim(self):
  source=self.root/'unsupported.jpg';source.write_bytes(b'\x00\x00\x00\x18ftypheic'+b'0'*64)
  # The pinned dependency is not installed on this host. This is a fail-closed
  # boundary fixture, not a claim that actual HEIC pixels were decoded here.
  with patch.dict(sys.modules,{'pillow_heif':None}),self.assertRaisesRegex(QualityError,'decoder_unavailable'):a.decoded_aerial_original(source)
  self.assertEqual(source.read_bytes()[8:12],b'heic')
 def test_actual_native_4k_qualification_whole120frames_and_measured_facts(self):
  source=self.root/'paid-source.mp4';subprocess.run(['ffmpeg','-v','error','-nostdin','-y','-f','lavfi','-i','testsrc2=size=3840x2160:rate=24:duration=5','-an','-vf','setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709','-c:v','libx264','-preset','ultrafast','-crf','20','-threads','2','-pix_fmt','yuv420p','-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709',str(source)],check=True)
  sha=hashlib.sha256(source.read_bytes()).hexdigest();t=self.task(False);t['clip'].update(sha256=sha,bytes=source.stat().st_size)
  with patch.object(a,'download',side_effect=self.local_read(source)):out=renderer.render(t,{'media.fixture.invalid'},str(self.root))['result']
  r=out['receipt'];require_cfr24(out['master'],probe(out['master']),exact_frames={120});self.assertEqual((r['width'],r['height'],r['duration_s'],r['fps'],r['total_frames']),(1920,1080,5,24,120));self.assertEqual([f['frame_index']for f in r['frames']],[0,60,119]);self.assertEqual([r[k]for k in ['codec','pix_fmt','color_space','sample_aspect_ratio','rotation','audio_streams']],['h264','yuv420p','bt709','1:1',0,0]);self.assertEqual(r['source_clip_sha256'],sha);self.assertEqual(r['source_clip_bytes'],source.stat().st_size);self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(),sha)
  (self.root/'measured-qualification.json').write_text(json.dumps({k:v for k,v in r.items()if k!='frames'},indent=2)+'\n')
if __name__=='__main__':unittest.main()

class Practical(unittest.TestCase):
 setUp=Processing.setUp
 tearDown=Processing.tearDown
 task=Processing.task
 local_read=Processing.local_read
 def encode(self,path,width=1922,height=1080,count=121,rate=24,hdr=False,tagged=False):
  filters='setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc'if hdr else 'setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709'if tagged else None
  cmd=['ffmpeg','-v','error','-nostdin','-y','-f','lavfi','-i',f'testsrc2=size={width}x{height}:rate={rate}','-frames:v',str(count),'-an']
  if filters:cmd+=['-vf',filters]
  cmd+=['-c:v','libx264','-preset','ultrafast','-crf','20','-threads','2','-pix_fmt','yuv420p',str(path)];subprocess.run(cmd,check=True)
 def qualify(self,source):
  t=self.task(False);t['clip'].update(sha256=hashlib.sha256(source.read_bytes()).hexdigest(),bytes=source.stat().st_size)
  with patch.object(a,'download',side_effect=self.local_read(source)):return renderer.render(t,{'media.fixture.invalid'},str(self.root))['result']
 def test_actual121_untagged_one_chroma_rounding_preserves_every_frame(self):
  source=self.root/'provider121.mp4';self.encode(source);sha=hashlib.sha256(source.read_bytes()).hexdigest();out=self.qualify(source);r=out['receipt'];require_cfr24(out['master'],probe(out['master']),exact_frames={121})
  self.assertEqual(r['source_clip_bytes'],source.stat().st_size);self.assertEqual(r['total_frames'],121);self.assertEqual(r['duration_s'],121/24);self.assertEqual([x['frame_index']for x in r['frames']],[0,60,120]);self.assertEqual(r['source_metadata']['width'],1922);self.assertEqual(r['source_metadata']['height'],1080);self.assertEqual(r['source_color_interpretation'],'untagged-sdr-bt709-defaults');self.assertIsNone(r['source_metadata']['color_transfer']);self.assertEqual((r['width'],r['height']),(1920,1080));self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(),sha)
  (self.root/'actual121-source-and-qualified.json').write_text(json.dumps({k:v for k,v in r.items()if k!='frames'},indent=2)+'\n')
 def test_actual_hdr_cadence_and_corruption_refuse(self):
  for label,args in [('hdr',{'hdr':True}),('cadence',{'rate':30,'count':151}),('wrong-aspect',{'width':1920,'height':1200})]:
   source=self.root/(label+'.mp4');self.encode(source,**args)
   with self.subTest(label=label),self.assertRaises((QualityError,ValueError,subprocess.CalledProcessError)):self.qualify(source)
  source=self.root/'broken.mp4';source.write_bytes(b'not a video')
  with self.assertRaises((QualityError,ValueError,subprocess.CalledProcessError)):self.qualify(source)


class SourceRange(unittest.TestCase):
 setUp=Processing.setUp
 tearDown=Processing.tearDown
 task=Processing.task
 local_read=Processing.local_read
 qualify=Practical.qualify
 def test_actual_fullrange_yuvj420p_refused_before_normalization(self):
  source=self.root/'fullrange-yuvj420p.mp4'
  subprocess.run(['ffmpeg','-v','error','-nostdin','-y','-f','lavfi','-i','testsrc2=size=1920x1080:rate=24','-frames:v','120','-an','-c:v','libx264','-preset','ultrafast','-crf','20','-threads','2','-pix_fmt','yuvj420p','-color_range','pc',str(source)],check=True)
  measured=probe(source);self.assertEqual(measured['streams'][0]['pix_fmt'],'yuvj420p');self.assertEqual(measured['streams'][0]['color_range'],'pc');sha=hashlib.sha256(source.read_bytes()).hexdigest()
  with self.assertRaisesRegex(QualityError,'bounded_native_aerial_source_required'):self.qualify(source)
  self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(),sha)
  self.assertFalse((self.root/'qualified.mp4').exists())
  (self.root/'fullrange-refused.json').write_text(json.dumps({'source_sha256':sha,'source_bytes':source.stat().st_size,'measured_pix_fmt':'yuvj420p','measured_range':'pc','refused_before_normalization':True},indent=2)+'\n')
