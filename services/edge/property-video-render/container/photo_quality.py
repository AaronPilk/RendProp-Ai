"""Private fixed-feature photo comparison derivatives; no judge/provider calls.

Original/prepared/candidate bytes remain immutable. Every crop names its own
EXIF-normalized, ICC-converted RGB parent. No alignment, fill, or upsampling.
"""
import concurrent.futures
import datetime
import hashlib
import os
import struct
import threading
import time
import uuid
from pathlib import Path
from PIL import Image
from capabilities import download, digest, upload
from prepare_image import decoded_srgb, MAX_SOURCE_BYTES

POLICY = 'photo-fixed-features-v1'
REGIONS = ('whole', 'tl', 'tr', 'bl', 'br')
MAX_DERIVATIVE_BYTES = 6_000_000
MAX_PREPARED_SOURCE_BYTES = 9_000_000
# Re-encode only inspection copies from retained normalized RGB crops. Each
# pass uses the same quality for source/candidate and all ten fixed views.
DERIVATIVE_JPEG_QUALITIES = (97, 94, 91, 88, 85, 82, 80)


def validate_photo_task(task):
    allowed = {'state','action','policy','check_id','evidence_id','lease_token','expires_at','prepared_source','candidate'}
    if not isinstance(task,dict) or set(task)-allowed or task.get('action') != 'prepare_photo_quality' or task.get('policy') != POLICY:
        raise ValueError('closed_photo_quality_task_required')
    for key in ('check_id','evidence_id','lease_token'):
        value = task.get(key)
        if not isinstance(value,str) or str(uuid.UUID(value)) != value:
            raise ValueError('photo_quality_identity_required')
    expiry = datetime.datetime.fromisoformat(task['expires_at'].replace('Z','+00:00'))
    if expiry.tzinfo is None or not time.time() < expiry.timestamp() <= time.time()+610:
        raise ValueError('bounded_photo_quality_lease_required')
    for key in ('prepared_source','candidate'):
        item = task[key]
        if (not isinstance(item,dict) or set(item)-{'bucket','key','etag','bytes','sha256','mime','url'}
                or item.get('mime') not in {'image/jpeg','image/png','image/webp'}
                or not isinstance(item.get('bytes'),int) or isinstance(item['bytes'],bool) or not 1 <= item['bytes'] <= (MAX_PREPARED_SOURCE_BYTES if key == 'prepared_source' else MAX_SOURCE_BYTES)
                or not isinstance(item.get('sha256'),str) or len(item['sha256'])!=64 or any(c not in '0123456789abcdef' for c in item['sha256'])
                or any(not isinstance(item.get(k),str) or not item[k] or len(item[k])>2048 for k in ('bucket','key','etag'))):
            raise ValueError('exact_owned_photo_required')


def pixel_digest(image):
    # Normative byte layout: ASCII RGB8, uint32 big-endian width and height,
    # then tightly packed row-major RGB8 pixels (top-left origin).
    return hashlib.sha256(b'RGB8'+struct.pack('>II',*image.size)+image.tobytes()).hexdigest()


def crop_rectangles(width,height):
    if width < 2 or height < 2:
        raise ValueError('photo_quality_parent_too_small')
    x,y = width//2,height//2
    return {'whole':(0,0,width,height),'tl':(0,0,x,y),'tr':(x,0,width-x,y),
            'bl':(0,y,x,height-y),'br':(x,y,width-x,height-y)}


# The two parents and the ten views are independent. Pillow releases the GIL
# while it decodes, resamples and encodes, so a small thread pool uses both
# CPUs without changing any byte: every view keeps its own image object and
# every pass still uses one quality for all ten views.
ENCODE_WORKERS = max(2, min(4, os.cpu_count() or 2))
UPLOAD_WORKERS = 5
# decoded_srgb() uses warnings.catch_warnings(), which swaps process-wide
# state and is not safe to enter from two threads at once. Downloads, pixel
# hashing, cropping, resampling and encoding still overlap.
DECODE_LOCK = threading.Lock()


def write_comparison(crop,profile,target,quality):
    crop.save(target,'JPEG',quality=quality,subsampling=0,optimize=True,icc_profile=profile)
    return target.stat().st_size


def measured_comparison(crop,target):
    """Decode-check and hash the one file that will actually be uploaded."""
    with Image.open(target) as check:
        check.load()
        if check.format!='JPEG' or check.mode!='RGB' or check.size!=crop.size or check.getexif():
            raise ValueError('photo_quality_derivative_decode_conflict')
    return {'sha256':digest(target),'bytes':target.stat().st_size,'width':crop.width,'height':crop.height}


def encode_comparison(crop,profile,target,quality):
    write_comparison(crop,profile,target,quality)
    return measured_comparison(crop,target)


def prepare_parent(task,directory,hosts,role,field):
    """Download, admit and decode one parent, then cut its five fixed views."""
    path = directory/f'{role}-master'
    input_sha = download(task[field],path,hosts,max_bytes=MAX_PREPARED_SOURCE_BYTES if field == 'prepared_source' else MAX_SOURCE_BYTES)
    with Image.open(path, formats=('JPEG', 'PNG', 'WEBP')) as header:
        if min(header.size)<2 or max(header.size)>16384 or header.width*header.height>24_000_000:
            raise ValueError('photo_quality_parent_geometry_refused')
    with DECODE_LOCK:
        image,profile = decoded_srgb(path)
    path.unlink()
    views=[]
    try:
        parent={'role':role,'input_sha256':input_sha,'normalized_width':image.width,'normalized_height':image.height,
                'normalized_pixel_sha256':pixel_digest(image),'normalization':'exif-icc-srgb-v1',
                'pixel_hash_policy':'rgb8-dimensions-row-major-v1'}
        for region,(left,top,width,height) in crop_rectangles(*image.size).items():
            crop = image.crop((left,top,left+width,top+height))
            views.append((region,crop,{'left':left,'top':top,'width':width,'height':height}))
            edge = 2048 if region == 'whole' else 1024
            crop.thumbnail((edge,edge),Image.Resampling.LANCZOS)
        return {'parent':parent,'size':image.size,'profile':profile,'views':views}
    except BaseException:
        for _,crop,_ in views:
            crop.close()
        raise
    finally:
        image.close()


def prepare_photo_quality(task,directory,hosts):
    validate_photo_task(task)
    roles=(('source','prepared_source'),('candidate','candidate'))
    crops={}
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            pending=[pool.submit(prepare_parent,task,directory,hosts,role,field) for role,field in roles]
            # Leaving the pool waits for both parents, so a refused parent
            # never leaves the other one decoding into a removed directory.
            done=[]
            failure=None
            for future in pending:
                try:
                    done.append(future.result())
                except BaseException as error:  # keep the first, close the rest below
                    failure=failure or error
            for parent in done:
                for region,crop,_ in parent['views']:
                    crops[(parent['parent']['role'],region)]=(crop,parent['profile'])
            if failure:
                raise failure
        parents=[parent['parent'] for parent in done]
        (sw,sh),(cw,ch)=[parent['size'] for parent in done]
        if abs(sw*ch-cw*sh)>max(sw,sh,cw,ch):
            raise ValueError('photo_quality_parent_aspect_conflict')
        order=[(parent['parent']['role'],region,rectangle) for parent in done for region,_,rectangle in parent['views']]
        paths={(role,region):directory/f'{role}-{region}.jpg' for role,region,_ in order}
        selected=None
        with concurrent.futures.ThreadPoolExecutor(max_workers=ENCODE_WORKERS) as pool:
            def encode(key,quality):
                crop,profile=crops[key]
                return write_comparison(crop,profile,paths[key],quality)
            for quality in DERIVATIVE_JPEG_QUALITIES:
                # Size alone decides the pass; only the chosen pass is decoded
                # and hashed, instead of re-reading files that get replaced.
                if sum(pool.map(lambda key:encode(key,quality),[(role,region) for role,region,_ in order]))<=MAX_DERIVATIVE_BYTES:
                    selected=quality
                    break
            if selected is None:
                raise ValueError('photo_quality_comparison_budget_exceeded')
            measured=list(pool.map(lambda key:measured_comparison(crops[key][0],paths[key]),[(role,region) for role,region,_ in order]))
        images=[{'role':role,'region':region,**facts,'crop':rectangle} for (role,region,rectangle),facts in zip(order,measured)]
        if sum(x['bytes'] for x in images)>MAX_DERIVATIVE_BYTES:
            raise ValueError('photo_quality_comparison_budget_exceeded')
        manifest={'policy':POLICY,'prepared_sha256':task['prepared_source']['sha256'],
                  'candidate_sha256':task['candidate']['sha256'],'parents':parents,'images':images}
        receipt={'check_id':task['check_id'],'evidence_id':task['evidence_id'],'lease_token':task['lease_token'],'manifest':manifest}
        # HTTP exposes only the unchanged exact receipt; quality is private proof.
        return {'receipt':receipt,'photo_quality_images':paths,'comparison_jpeg_quality':selected}
    finally:
        for crop,_ in crops.values():
            crop.close()


def upload_photo_quality(prepared,output,hosts):
    receipt=prepared['result']['receipt']
    expiry=datetime.datetime.fromisoformat(output['expires_at'].replace('Z','+00:00'))
    if expiry.tzinfo is None or expiry.timestamp()<=time.time() or output.get('check_id')!=receipt['check_id'] or output.get('evidence_id')!=receipt['evidence_id']:
        raise ValueError('photo_quality_output_identity_conflict')
    expected={(x['role'],x['region']):x for x in receipt['manifest']['images']}
    reserved=output.get('images')
    if not isinstance(reserved,list) or len(reserved)!=10 or len({(x['role'],x['region'])for x in reserved})!=10 or set(expected)!={(x['role'],x['region'])for x in reserved}:
        raise ValueError('photo_quality_output_roles_conflict')
    for item in reserved:
        measured=expected[(item['role'],item['region'])]
        if any(item.get(k)!=measured[k] for k in ('bytes','sha256','width','height')):
            raise ValueError('photo_quality_output_measurement_conflict')
    def put(item):
        path=prepared['result']['photo_quality_images'][(item['role'],item['region'])]
        etag=upload(item['put_url'],path,'image/jpeg',hosts,item['headers'],allow_existing=True)
        # Existing immutable PUT412 is not success authority. The Edge callback
        # independently HEADs/rehashes the reserved exact object before ready.
        row={k:item[k]for k in ('role','region','bucket','key','bytes','sha256','width','height','crop','mime')}
        if etag:row['etag']=etag
        return row
    # Ten small independent immutable PUTs; receipts keep the reserved order.
    with concurrent.futures.ThreadPoolExecutor(max_workers=UPLOAD_WORKERS) as pool:
        receipts=list(pool.map(put,reserved))
    return {'check_id':receipt['check_id'],'evidence_id':receipt['evidence_id'],'lease_token':receipt['lease_token'],'receipts':receipts}
