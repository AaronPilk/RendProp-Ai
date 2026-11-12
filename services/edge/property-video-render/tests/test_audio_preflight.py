import hashlib
import math
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'container'))
from renderer import render,validate_task
from compose import QualityError,probe,run

class AudioPreflight(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.tmp=tempfile.TemporaryDirectory();cls.root=Path(cls.tmp.name);full=os.environ.get('RENDER_TEST_FFMPEG');real=shutil.which
  cls.which=patch('shutil.which',side_effect=lambda name:full if full and name=='ffmpeg' else real(name));cls.which.start()
  for suffix,codec in [('m4a','aac'),('mp3','libmp3lame')]:
   for duration in [10,20]:
    run([shutil.which('ffmpeg'),'-v','error','-y','-f','lavfi','-i',f'sine=frequency=1000:duration={duration}:sample_rate=48000','-c:a',codec,str(cls.root/f'voice-{duration}.{suffix}')])
 @classmethod
 def tearDownClass(cls):cls.which.stop();cls.tmp.cleanup()
 def task(self,path,limit):
  return {'job_id':'00000000-0000-4000-8000-000000000001','state':'queued','action':'inspect_audio','lease_token':'00000000-0000-4000-8000-000000000002','manifest_sha256':'a'*64,'source':{'url':'https://media.example.test/voice?signature=closed','bytes':path.stat().st_size,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'etag':'"owned"'},'max_duration_s':limit,'expires_at':'2099-01-01T00:00:00Z'}
 def inspect(self,path,limit):
  task=self.task(path,limit)
  def download(item,target,hosts,**options):
   self.assertEqual(options['max_bytes'],20*1024*1024);self.assertEqual(item['sha256'],hashlib.sha256(path.read_bytes()).hexdigest());shutil.copyfile(path,target);return item['sha256']
  with patch('renderer.download',side_effect=download),patch('renderer.compose_task',side_effect=AssertionError('preflight must not compose clips')),patch('renderer.extract',side_effect=AssertionError('preflight must not read video frames')):result=render(task,{'media.example.test'},str(self.root))
  self.assertEqual(list(result['directory'].iterdir()),[], 'metadata probe retains no narration copy or rendered output');shutil.rmtree(result['directory'])
  return result['result']
 def test_measured_m4a_mp3_cut_fit_transition_refusal_and_metadata_only(self):
  for suffix in ['m4a','mp3']:
   short=self.inspect(self.root/f'voice-10.{suffix}',10)
   self.assertEqual(short['audio_streams'],1);self.assertLessEqual(short['duration_s'],10.1);self.assertGreater(short['duration_s'],9.95)
   self.assertGreater(short['duration_s'],(10-8/30)+.1, 'same10-second narration is too long for two-shot dissolve')
   long=self.inspect(self.root/f'voice-20.{suffix}',10)
   self.assertGreater(long['duration_s'],10.1,'authoritative callback refuses before supplier phase');self.assertEqual(long['manifest_sha256'],'a'*64)
 def test_closed_bounds_corrupt_audio_and_cleanup(self):
  path=self.root/'voice-10.m4a';task=self.task(path,10)
  for changed in [{'max_duration_s':math.inf},{'max_duration_s':True},{'source':{**task['source'],'bytes':20*1024*1024+1}},{'source':{**task['source'],'sha256':'bad'}},{'arbitrary_provider_key':'never'}]:
   with self.assertRaises(ValueError):validate_task({**task,**changed})
  corrupt=self.root/'corrupt.m4a';corrupt.write_bytes(b'not an audio stream')
  before=set(self.root.iterdir())
  with self.assertRaises(Exception):self.inspect(corrupt,10)
  self.assertEqual(set(self.root.iterdir()),before,'failed decode removes private work directory')
 def test_actual_multiple_audio_tracks_cannot_be_accepted_as_one_narration(self):
  dual=self.root/'dual.m4a'
  run([shutil.which('ffmpeg'),'-v','error','-y','-f','lavfi','-i','sine=frequency=440:duration=1','-f','lavfi','-i','sine=frequency=880:duration=1','-map','0:a','-map','1:a','-c:a','aac',str(dual)])
  self.assertEqual(len([s for s in probe(dual)['streams']if s['codec_type']=='audio']),2)
  before=set(self.root.iterdir())
  with self.assertRaisesRegex(QualityError,'one_narration_stream_required'):self.inspect(dual,10)
  self.assertEqual(set(self.root.iterdir()),before)
