"""Exact owned original preparation and paid-clip qualification, without generation."""
from __future__ import annotations
import base64
import io
import math
import shutil
from pathlib import Path
from PIL import Image, ImageCms
from capabilities import digest, download
from compose import QualityError, probe, require_cfr24, run
from prepare_image import decoded_srgb, MAX_SOURCE_BYTES, MAX_OUTPUT_BYTES
from photo_motion_profile import MODE, checked_producer

INPUT_PROFILE='aerial-opening-input-v1'
QUALIFY_PROFILE='aerial-opening-qualify-cfr24'
HEX=set('0123456789abcdef')


def decoded_aerial_original(source):
    """New aerial-only HEIF decode; old photo/AI normalizers remain closed."""
    try:
        return decoded_srgb(source)
    except ValueError as error:
        if str(error)!='single_supported_photo_required':raise
    with open(source,'rb')as stream:header=stream.read(64)
    if len(header)<12 or header[4:8]!=b'ftyp' or header[8:12]not in{b'heic',b'heix',b'mif1'}:
        raise QualityError('single_supported_aerial_original_required')
    try:
        import pillow_heif
    except ImportError as error:
        raise QualityError('aerial_heif_decoder_unavailable')from error
    # Do not silently tone-map HDR, choose a thumbnail, or reapply HEIF's
    # already decoded orientation through a second EXIF transpose.
    file=pillow_heif.open_heif(source,convert_hdr_to_8bit=False,hdr_to_16bit=True)
    if len(file)!=1 or file.mimetype not in{'image/heic','image/heif'}:
        raise QualityError('single_supported_aerial_original_required')
    primary=file[file.primary_index]
    info=primary.info
    if(info.get('bit_depth')!=8 or primary.mode not in{'RGB','RGBA'}or min(primary.size)<1 or primary.size[0]*primary.size[1]>100000000
       or info.get('pixel_aspect_ratio',(1,1))not in[(1,1),None]
       or any(info.get(k)is not None for k in['content_light_level','mastering_display_colour_volume','ambient_viewing_environment','nominal_diffuse_white_luminance'])):
        raise QualityError('bounded_sdr_aerial_original_required')
    image=primary.to_pillow();profile=info.get('icc_profile')
    srgb=ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB'))
    alpha=image.getchannel('A')if image.mode=='RGBA'else None
    if profile:
        if not isinstance(profile,bytes)or not 1<=len(profile)<=1024*1024:raise QualityError('bounded_color_profile_required')
        try:image=ImageCms.profileToProfile(image.convert('RGB'),ImageCms.ImageCmsProfile(io.BytesIO(profile)),srgb,outputMode='RGB')
        except(ValueError,TypeError,OSError,ImageCms.PyCMSError)as error:raise QualityError('photo_color_profile_refused')from error
    else:
        nclx=info.get('nclx_profile',{})
        if nclx.get('color_primaries')!=1 or nclx.get('transfer_characteristics')!=13:raise QualityError('explicit_aerial_color_profile_required')
        image=image.convert('RGB')
    if alpha is not None:
        background=Image.new('RGB',image.size,'white');background.paste(image,mask=alpha);image=background
    return image.copy(),srgb.tobytes()


def _hash(value):
    return isinstance(value,str) and len(value)==64 and all(c in HEX for c in value)


def _media(value,maximum):
    return (isinstance(value,dict) and set(value)=={'url','sha256','bytes','etag'} and isinstance(value['url'],str)
            and _hash(value['sha256']) and type(value['bytes']) is int and 1<=value['bytes']<=maximum
            and isinstance(value['etag'],str) and 1<=len(value['etag'])<=512)


def validate_crop(crop,aspect):
    if not isinstance(crop,dict) or set(crop)!={'x','y','width','height','source_width','source_height'} or any(type(v)is not int for v in crop.values()):
        raise QualityError('closed_reviewed_aerial_crop_required')
    x,y,w,h,sw,sh=(crop[k]for k in ['x','y','width','height','source_width','source_height'])
    n,d=(16,9)if aspect=='16:9'else(9,16)
    if x<0 or y<0 or min(w,h,sw,sh)<1 or sw*sh>100000000 or x+w>sw or y+h>sh or w*d!=h*n or w<(1920 if n==16 else 1080)or h<(1080 if n==16 else 1920):
        raise QualityError('exact_reviewed_aerial_crop_required')
    return crop


def validate_task(task):
    if not isinstance(task,dict):raise QualityError('closed_aerial_processing_task_required')
    profile=task.get('composition_profile');prepare=profile==INPUT_PROFILE
    common={'state','action','job_id','lease_token','manifest_sha256','source_mode','composition_profile','producer_identity','aspect','output','expires_at'}
    if (profile not in {INPUT_PROFILE,QUALIFY_PROFILE} or set(task)!=common|({'source','reviewed_crop'}if prepare else{'clip','source_sha256'})
            or task.get('source_mode')!=MODE or task.get('action')!=('prepare_image'if prepare else'compose')
            or task.get('state')!=('preparing'if prepare else'qualifying') or task.get('aspect')not in{'16:9','9:16'} or not _hash(task.get('manifest_sha256'))
            or not _media(task.get('source')if prepare else task.get('clip'),MAX_SOURCE_BYTES if prepare else 128*1024*1024)
            or not isinstance(task['output'],dict)or set(task['output'])!=({'asset_id','key'}if prepare else{'asset_id','key','poster_asset_id','poster_key'})):
        raise QualityError('closed_aerial_processing_task_required')
    checked_producer(task)
    if prepare:validate_crop(task['reviewed_crop'],task['aspect'])
    elif not _hash(task['source_sha256']):raise QualityError('aerial_original_digest_required')


def jpeg_frame(source, index, target, width, height, maximum_edge=None):
    # Decode the tagged BT709 video to actual RGB before JPEG's conventional
    # matrix, instead of relabeling YUV709 coefficients as a JPEG image.
    raw=run([shutil.which('ffmpeg'),'-hide_banner','-loglevel','error','-nostdin','-protocol_whitelist','file,pipe','-i',str(source),'-vf',f'select=eq(n\\,{index})','-fps_mode','passthrough','-frames:v','1','-f','rawvideo','-pix_fmt','rgb24','pipe:1'],timeout=30).stdout
    if len(raw)!=width*height*3:raise QualityError('aerial_frame_decode_conflict')
    image=Image.frombytes('RGB',(width,height),raw)
    if maximum_edge:image.thumbnail((maximum_edge,maximum_edge),Image.Resampling.LANCZOS)
    from PIL import ImageCms
    image.save(target,'JPEG',quality=90 if maximum_edge else 97,subsampling=0,optimize=True,icc_profile=ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes())


def prepare_source(task,directory,hosts):
    validate_task(task)
    original,target=directory/'owned-original',directory/'reviewed-aerial.jpg'
    source_sha=download(task['source'],original,hosts,max_bytes=MAX_SOURCE_BYTES)
    image,profile=decoded_aerial_original(original)
    c=task['reviewed_crop']
    if image.size!=(c['source_width'],c['source_height']):raise QualityError('reviewed_aerial_oriented_source_changed')
    crop=image.crop((c['x'],c['y'],c['x']+c['width'],c['y']+c['height']))
    n,d=(16,9)if task['aspect']=='16:9'else(9,16)
    unit=min(c['width']//n,c['height']//d,2048//max(n,d))
    width,height=unit*n,unit*d
    crop=crop.resize((width,height),Image.Resampling.LANCZOS)
    crop.save(target,'JPEG',quality=97,subsampling=0,optimize=True,icc_profile=profile)
    if not 1<=target.stat().st_size<=MAX_OUTPUT_BYTES:raise QualityError('bounded_reviewed_aerial_jpeg_required')
    with Image.open(target)as check:
        check.load()
        if check.format!='JPEG'or check.mode!='RGB'or check.size!=(width,height)or check.getexif():raise QualityError('reviewed_aerial_jpeg_decode_conflict')
    if digest(original)!=source_sha:raise QualityError('aerial_original_changed_during_prepare')
    original.unlink()
    return{'receipt':{'job_id':task['job_id'],'lease_token':task['lease_token'],'manifest_sha256':task['manifest_sha256'],'asset_id':task['output']['asset_id'],
            'source_mode':MODE,'composition_profile':INPUT_PROFILE,'producer_identity':checked_producer(task),'source_sha256':source_sha,'source_bytes':task['source']['bytes'],
            'reviewed_crop':c,'width':width,'height':height,'bytes':target.stat().st_size,'sha256':digest(target),'mime':'image/jpeg'},'prepared_image':target}


def qualify_clip(task,directory,hosts):
    validate_task(task)
    source,master,poster=directory/'paid-original.mp4',directory/'qualified.mp4',directory/'poster.jpg'
    sha=download(task['clip'],source,hosts,max_bytes=128*1024*1024);source_bytes=source.stat().st_size
    facts=probe(source);streams=facts.get('streams',[])
    if len(streams)!=1 or streams[0].get('codec_type')!='video':raise QualityError('silent_single_aerial_source_required')
    v=streams[0];w,h=v.get('width',0),v.get('height',0);aspect=task['aspect'];W,H=(1920,1080)if aspect=='16:9'else(1080,1920)
    try:count=int(v.get('nb_frames',''));duration=float(facts['format']['duration'])
    except(TypeError,ValueError,KeyError)as error:raise QualityError('measured_aerial_frames_required')from error
    rounding=abs(h-w*H/W)if W>H else abs(w-h*W/H)
    if(v.get('codec_name')!='h264'or v.get('pix_fmt')!='yuv420p'or type(w)is not int or type(h)is not int
       or w<W or h<H or max(w,h)>7680 or w*h>33177600 or rounding>2 or v.get('sample_aspect_ratio','1:1')!='1:1'
       or any(int(x.get('rotation',0))!=0 for x in v.get('side_data_list',[]))or str(v.get('tags',{}).get('rotate','0'))not in{'0','0.0'}
       or any(x.get('side_data_type')in{'Mastering display metadata','Content light level metadata','HDR Dynamic Metadata SMPTE2094-40 (HDR10+)'}for x in v.get('side_data_list',[]))
       or count not in{120,121}or not math.isfinite(duration)or abs(duration-count/24)>.001):raise QualityError('bounded_native_aerial_source_required')
    require_cfr24(source,facts,exact_frames={count})
    # Record actual tags separately. Missing SDR ancillary tags are explicit
    # BT709 defaults, never relabeled as measured source metadata or HDR proof.
    tags={k:v.get(k)for k in['color_space','color_transfer','color_primaries','color_range']}
    unknown={None,'unknown','unspecified'}
    defaults={'color_space':'bt709','color_transfer':'bt709','color_primaries':'bt709','color_range':'tv'}
    color={k:defaults[k]if tags[k]in unknown else tags[k]for k in tags}
    if(color['color_space']not in{'bt709','bt470bg','smpte170m','bt2020nc'}or color['color_transfer']not in{'bt709','gamma28','smpte170m','bt2020-10','bt2020-12'}or color['color_primaries']not in{'bt709','bt470bg','smpte170m','bt2020'}or color['color_range']not in{'tv','pc'}):raise QualityError('supported_sdr_aerial_source_required')
    basis='untagged-sdr-bt709-defaults'if any(tags[k]in unknown for k in tags)else'tagged-sdr'
    metadata={'width':w,'height':h,'total_frames':count,'duration_s':duration,'fps':24,'codec':v['codec_name'],'pix_fmt':v['pix_fmt'],**tags,'sample_aspect_ratio':v.get('sample_aspect_ratio'),'rotation':0,'audio_streams':0}
    filters=f"setparams=color_primaries={color['color_primaries']}:color_trc={color['color_transfer']}:colorspace={color['color_space']}:range={color['color_range']},colorspace=all=bt709:range=tv:format=yuv420p,scale={W}:{H}:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos,pad={W}:{H}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1"
    # Spatial fit/pad only. Keep every native frame, cadence and full duration;
    # there is no trim, fps filter, interpolation, scene crop or upscaling.
    run([shutil.which('ffmpeg'),'-hide_banner','-loglevel','error','-nostdin','-y','-xerror','-err_detect','explode','-protocol_whitelist','file,pipe','-i',str(source),'-map','0:v:0','-an',
         '-vf',filters,'-fps_mode','passthrough','-c:v','libx264','-preset','fast','-crf','18','-threads','2','-pix_fmt','yuv420p',
         '-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709','-movie_timescale','24000','-video_track_timescale','24000','-movflags','+faststart',str(master)])
    measured=probe(master);require_cfr24(master,measured,exact_frames={count})
    video=next(v for v in measured['streams']if v['codec_type']=='video')
    if((video['width'],video['height'])!=(W,H)or abs(float(measured['format']['duration'])-count/24)>.001 or len(measured['streams'])!=1 or video.get('codec_name')!='h264'or video.get('pix_fmt')!='yuv420p'or tuple(video.get(k)for k in['color_space','color_transfer','color_primaries'])!=('bt709','bt709','bt709')or video.get('sample_aspect_ratio')!='1:1'or any(int(x.get('rotation',0))!=0 for x in video.get('side_data_list',[]))or str(video.get('tags',{}).get('rotate','0'))not in{'0','0.0'}):raise QualityError('aerial_qualification_changed_timeline')
    frames=[]
    for index in [0,count//2,count-1]:
        image=directory/f'frame-{index}.jpg'
        jpeg_frame(master,index,image,W,H,1024)
        if not 1<=image.stat().st_size<=384*1024:raise QualityError('bounded_aerial_qc_frame_required')
        frames.append({'frame_index':index,'image_b64':base64.b64encode(image.read_bytes()).decode(),'mime':'image/jpeg'})
    jpeg_frame(master,0,poster,W,H)
    if digest(source)!=sha:raise QualityError('paid_aerial_source_changed')
    source.unlink()
    if not 1<=master.stat().st_size<=128*1024*1024 or not 1<=poster.stat().st_size<=10*1024*1024:raise QualityError('bounded_aerial_output_required')
    receipt={'job_id':task['job_id'],'lease_token':task['lease_token'],'manifest_sha256':task['manifest_sha256'],'asset_id':task['output']['asset_id'],'poster_asset_id':task['output']['poster_asset_id'],
             'source_mode':MODE,'composition_profile':QUALIFY_PROFILE,'producer_identity':checked_producer(task),'source_sha256':task['source_sha256'],'source_clip_sha256':sha,'source_clip_bytes':source_bytes,
             'width':W,'height':H,'duration_s':count/24,'fps':24,'total_frames':count,'source_metadata':metadata,'source_color_interpretation':basis,'codec':video['codec_name'],'pix_fmt':video['pix_fmt'],'color_space':video['color_space'],'sample_aspect_ratio':video['sample_aspect_ratio'],'rotation':0,'audio_streams':len([x for x in measured['streams']if x['codec_type']=='audio']),'bytes':master.stat().st_size,'sha256':digest(master),'poster_bytes':poster.stat().st_size,'poster_sha256':digest(poster),'frames':frames}
    return{'receipt':receipt,'master':master,'poster':poster}
