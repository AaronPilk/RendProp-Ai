"""Closed restrained 2D camera movement using only pixels in the saved photo."""
import shutil
from compose import QualityError, probe, run

MOTIONS={'fly_through','push_in','side_glide','pull_back'}
MIN_STATIC_CROP_EDGE=480


def motion_filter(source_width, source_height, width, height, motion):
    if motion not in MOTIONS:
        raise QualityError('closed_photo_motion_required')
    # Crop actual source to final aspect first. Never enlarge for overscan.
    crop_width=min(source_width,int(source_height*width/height))
    crop_height=min(source_height,int(source_width*height/width))
    crop_width-=crop_width%2;crop_height-=crop_height%2
    if crop_width<width or crop_height<height:
        raise QualityError('original_photo_lacks_1080_pixels')
    available=min(crop_width/width,crop_height/height)-1
    margin=max(0,min(.03,available))
    progress='min(1,on/149)'
    if margin<.0001:
        zoom,x,y='1','0','0'  # Exact1080 cannot move without inventing pixels.
    elif motion=='push_in':
        span=min(.02,margin)
        zoom=f'1+{span:.9f}*{progress}';x='(iw-iw/zoom)/2';y='(ih-ih/zoom)/2'
    elif motion=='pull_back':
        zoom=f'1+{margin:.9f}*(1-{progress})';x='(iw-iw/zoom)/2';y='(ih-ih/zoom)/2'
    elif motion=='side_glide':
        zoom=f'1+{margin:.9f}';x=f'(iw-iw/zoom)*{progress}';y='(ih-ih/zoom)/2'
    else:
        # A small forward/diagonal glide in this photo, not generated roomgeometry.
        zoom=f'1+{margin:.9f}*{progress}'
        x=f'(iw-iw/zoom)*(0.65-0.30*{progress})'
        y=f'(ih-ih/zoom)*(0.65-0.15*{progress})'
    return f"crop={crop_width}:{crop_height},zoompan=z='{zoom}':x='{x}':y='{y}':d=150:s={width}x{height}:fps=30,setsar=1,format=yuv420p"


def encode_photo_motion(photo, clip, aspect, motion):
    width,height=(1920,1080)if aspect=='16:9'else(1080,1920)
    facts=probe(photo);streams=[item for item in facts['streams']if item['codec_type']=='video']
    if len(streams)!=1:
        raise QualityError('one_original_photo_required')
    source=streams[0]
    if source['width']*source['height']>100_000_000:
        raise QualityError('bounded_photo_pixels_required')
    filters=motion_filter(source['width'],source['height'],width,height,motion)
    run([shutil.which('ffmpeg'),'-hide_banner','-loglevel','error','-nostdin','-y','-i',str(photo),'-vf',filters,
         '-an','-frames:v','150','-c:v','libx264','-crf','18','-maxrate','24M','-bufsize','48M','-threads','2',
         '-movflags','+faststart',str(clip)])
    return filters


def static_saved_photo_filter(source_width, source_height, width, height):
    """A limited-detail still from existing pixels, never generated detail.

    This separate path is only for an explicitly selected saved-photo fallback.
    Motion and AI clips retain their existing native-pixel requirements.
    """
    if (width,height) not in {(1920,1080),(1080,1920)}:
        raise QualityError('static_saved_photo_requires_1080_canvas')
    crop_width=min(source_width,int(source_height*width/height))
    crop_height=min(source_height,int(source_width*height/width))
    crop_width-=crop_width%2;crop_height-=crop_height%2
    if min(crop_width,crop_height)<MIN_STATIC_CROP_EDGE:
        raise QualityError('saved_photo_crop_too_small')
    return (f'crop={crop_width}:{crop_height}:(iw-ow)/2:(ih-oh)/2,'
            f'scale={width}:{height}:flags=lanczos,setsar=1,fps=30,format=yuv420p')


def encode_static_saved_photo(photo, clip, aspect):
    """Five seconds at30fps from one normalized still, with no camera movement.

    The canvas is1080p; resizing cannot restore detail to a smaller source.
    No zoom, pan, AI-generated detail or padded/blurred panels are added.
    """
    if aspect not in {'16:9','9:16'}:
        raise QualityError('static_saved_photo_requires_1080_canvas')
    width,height=(1920,1080)if aspect=='16:9'else(1080,1920)
    videos=[item for item in probe(photo)['streams']if item['codec_type']=='video']
    if len(videos)!=1 or videos[0].get('codec_name')not in {'png','mjpeg'}:
        raise QualityError('one_normalized_saved_photo_required')
    source=videos[0]
    if source['width']*source['height']>100_000_000:
        raise QualityError('bounded_photo_pixels_required')
    filters=static_saved_photo_filter(source['width'],source['height'],width,height)
    run([shutil.which('ffmpeg'),'-hide_banner','-loglevel','error','-nostdin','-y',
         '-loop','1','-framerate','30','-i',str(photo),'-vf',filters,'-an',
         '-frames:v','150','-c:v','libx264','-crf','18','-maxrate','24M','-bufsize','48M',
         '-threads','2','-movflags','+faststart',str(clip)])
    return filters
