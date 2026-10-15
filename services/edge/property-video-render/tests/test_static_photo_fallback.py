"""Actual pixels/encoding for the explicit limited-detail saved-photo still."""
import hashlib
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from PIL import Image, ImageChops, ImageStat

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'container'))
from compose import QualityError, compose, probe, run
from photo_motion import motion_filter, static_saved_photo_filter, encode_static_saved_photo
from renderer import render
from test_cpu import task


class StaticSavedPhoto(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def source(self, size):
        width, height = size
        image = Image.new('RGB', size, 'yellow')
        image.paste('red', (width*3//8, height*3//8, width*5//8, height*5//8))
        image.paste('blue', (0, 0, 12, height))
        image.save(self.root/'saved.jpg', quality=97, subsampling=0)
        return self.root/'saved.jpg'

    def frame(self, clip, at, width, height):
        data = run([shutil.which('ffmpeg'), '-v', 'error', '-ss', str(at), '-i', str(clip),
                    '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']).stdout
        return Image.frombytes('RGB', (width, height), data)

    def red_bounds(self, image):
        red, green, blue = image.split()
        return ImageChops.multiply(red.point(lambda v:255 if v>200 else 0),
                                  green.point(lambda v:255 if v<80 else 0)).getbbox()

    def test_actual_portrait_and_landscape_stills_both_canvases_no_motion_or_bars(self):
        for size in [(896,1195), (1195,896)]:
            source = self.source(size)
            before = source.read_bytes()
            for aspect, width, height in [('16:9',1920,1080), ('9:16',1080,1920)]:
                with self.subTest(source=size, aspect=aspect):
                    clip = self.root/f'{size[0]}-{aspect.replace(":","-")}.mp4'
                    filters = encode_static_saved_photo(source, clip, aspect)
                    self.assertIn('flags=lanczos', filters)
                    self.assertNotIn('zoompan', filters)
                    self.assertNotIn('pad=', filters)
                    facts = probe(clip)
                    video = next(s for s in facts['streams'] if s['codec_type']=='video')
                    self.assertEqual((video['width'], video['height']), (width,height))
                    self.assertEqual(video['avg_frame_rate'], '30/1')
                    self.assertAlmostEqual(float(facts['format']['duration']), 5, places=2)
                    first = self.frame(clip, .03, width, height)
                    last = self.frame(clip, 4.9, width, height)
                    self.assertEqual(self.red_bounds(first), self.red_bounds(last), 'no camera movement')
                    self.assertLess(max(ImageStat.Stat(ImageChops.difference(first,last)).mean), 1)
                    sw, sh = size
                    cw = min(sw,int(sh*width/height)); ch = min(sh,int(sw*height/width))
                    cw -= cw%2; ch -= ch%2
                    with Image.open(source) as original:
                        expected = original.convert('RGB').crop(((sw-cw)//2,(sh-ch)//2,
                                    (sw-cw)//2+cw,(sh-ch)//2+ch)).resize((width,height),Image.Resampling.LANCZOS)
                    self.assertLess(max(ImageStat.Stat(ImageChops.difference(first,expected)).mean), 5,
                                    'full frame comes from exact center crop, no substitute or blurred panel')
                    for xy in [(20,20),(width-20,20),(20,height-20),(width-20,height-20)]:
                        self.assertGreater(sum(first.getpixel(xy)), 180, 'no black padding')
                    decoded = run([shutil.which('ffmpeg'),'-v','error','-nostdin','-xerror','-err_detect',
                                   'explode','-i',str(clip),'-f','null','-'])
                    self.assertEqual(decoded.returncode, 0)
                    self.assertEqual(source.read_bytes(), before, 'saved master bytes remain exact')

    def test_thumbnail_junk_and_fake4k_canvas_refused_while_motion_guard_stays_strict(self):
        for dims in [(160,120),(480,640),(400,2000)]:
            with self.assertRaisesRegex(QualityError,'saved_photo_crop_too_small'):
                static_saved_photo_filter(*dims,1920,1080)
        self.assertIn('scale=1920:1080',static_saved_photo_filter(855,480,1920,1080))
        with self.assertRaisesRegex(QualityError,'static_saved_photo_requires_1080_canvas'):
            static_saved_photo_filter(896,1195,3840,2160)
        for dims in [(896,1195),(1280,720),(1080,1920)]:
            with self.assertRaisesRegex(QualityError,'original_photo_lacks_1080_pixels'):
                motion_filter(*dims,1920,1080,'push_in')

    def test_actual_original_only_renderer_branch_and_unrelated_errors_never_become_stills(self):
        source = self.source((896,1195)); before = hashlib.sha256(source.read_bytes()).hexdigest()
        body = task(); body['sources'] = [{'position':0,'bytes':source.stat().st_size,'sha256':before,
            'url':'https://media.test/owned','motion_kind':'original_photo','motion':'push_in'}]
        def owned(_item,target,_hosts,**_kwargs):
            shutil.copyfile(source,target); return before
        with patch('renderer.download',side_effect=owned):
            result = render(body,{'media.test'},self.root)
        master = result['result']['master']; facts = probe(master)
        self.assertEqual((facts['streams'][0]['width'],facts['streams'][0]['height']),(1920,1080))
        self.assertAlmostEqual(float(facts['format']['duration']),5,places=2)
        self.assertEqual(self.red_bounds(self.frame(master,.03,1920,1080)),
                         self.red_bounds(self.frame(master,4.9,1920,1080)))
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(),before)
        shutil.rmtree(result['directory'])
        for error in [QualityError('closed_photo_motion_required'),OSError('reader failure')]:
            with patch('renderer.download',side_effect=owned),patch('renderer.encode_photo_motion',side_effect=error),patch('renderer.encode_static_saved_photo') as still:
                with self.assertRaises(type(error)):
                    render(body,{'media.test'},self.root)
                still.assert_not_called()
            self.assertEqual(list(self.root.iterdir()),[source], 'failed private work is removed')

    def test_actual_low_resolution_ai_video_still_fails_native1080_gate(self):
        clip = self.root/'low-ai.mp4'
        run([shutil.which('ffmpeg'),'-v','error','-nostdin','-f','lavfi','-i',
             'color=c=yellow:s=1280x720:r=30:d=5','-c:v','libx264','-preset','ultrafast',
             '-threads','2',str(clip)])
        with self.assertRaisesRegex(QualityError,'source lacks actual1080 framing pixels'):
            compose([clip],self.root/'refused-ai',aspect='16:9')


if __name__=='__main__':
    unittest.main()
