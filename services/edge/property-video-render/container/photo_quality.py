"""Private fixed-feature photo comparison derivatives; no judge/provider calls.

Original/prepared/candidate bytes remain immutable. Every crop names its own
EXIF-normalized, ICC-converted RGB parent. No alignment, fill, or upsampling.
"""
import datetime
import hashlib
import struct
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


def prepare_photo_quality(task,directory,hosts):
    validate_photo_task(task)
    parents,images,paths = [],[],{}
    sizes=[]
    for role,field in (('source','prepared_source'),('candidate','candidate')):
        path = directory/f'{role}-master'
        input_sha = download(task[field],path,hosts,max_bytes=MAX_PREPARED_SOURCE_BYTES if field == 'prepared_source' else MAX_SOURCE_BYTES)
        with Image.open(path) as header:
            if min(header.size)<2 or max(header.size)>16384 or header.width*header.height>24_000_000:
                raise ValueError('photo_quality_parent_geometry_refused')
        image,profile = decoded_srgb(path)
        path.unlink()
        sizes.append(image.size)
        parents.append({'role':role,'input_sha256':input_sha,'normalized_width':image.width,'normalized_height':image.height,
                        'normalized_pixel_sha256':pixel_digest(image),'normalization':'exif-icc-srgb-v1',
                        'pixel_hash_policy':'rgb8-dimensions-row-major-v1'})
        for region,(left,top,width,height) in crop_rectangles(*image.size).items():
            crop = image.crop((left,top,left+width,top+height))
            edge = 2048 if region == 'whole' else 1024
            crop.thumbnail((edge,edge),Image.Resampling.LANCZOS)
            target = directory/f'{role}-{region}.jpg'
            crop.save(target,'JPEG',quality=97,subsampling=0,optimize=True,icc_profile=profile)
            with Image.open(target) as check:
                check.load()
                if check.format!='JPEG' or check.mode!='RGB' or check.size!=crop.size or check.getexif():
                    raise ValueError('photo_quality_derivative_decode_conflict')
            row={'role':role,'region':region,'sha256':digest(target),'bytes':target.stat().st_size,
                 'width':crop.width,'height':crop.height,'crop':{'left':left,'top':top,'width':width,'height':height}}
            images.append(row);paths[(role,region)]=target
        image.close()
    (sw,sh),(cw,ch)=sizes
    if abs(sw*ch-cw*sh)>max(sw,sh,cw,ch):
        raise ValueError('photo_quality_parent_aspect_conflict')
    if sum(x['bytes'] for x in images)>MAX_DERIVATIVE_BYTES:
        raise ValueError('photo_quality_comparison_budget_exceeded')
    manifest={'policy':POLICY,'prepared_sha256':task['prepared_source']['sha256'],
              'candidate_sha256':task['candidate']['sha256'],'parents':parents,'images':images}
    receipt={'check_id':task['check_id'],'evidence_id':task['evidence_id'],'lease_token':task['lease_token'],'manifest':manifest}
    return {'receipt':receipt,'photo_quality_images':paths}


def upload_photo_quality(prepared,output,hosts):
    receipt=prepared['result']['receipt']
    expiry=datetime.datetime.fromisoformat(output['expires_at'].replace('Z','+00:00'))
    if expiry.tzinfo is None or expiry.timestamp()<=time.time() or output.get('check_id')!=receipt['check_id'] or output.get('evidence_id')!=receipt['evidence_id']:
        raise ValueError('photo_quality_output_identity_conflict')
    expected={(x['role'],x['region']):x for x in receipt['manifest']['images']}
    reserved=output.get('images')
    if not isinstance(reserved,list) or len(reserved)!=10 or len({(x['role'],x['region'])for x in reserved})!=10 or set(expected)!={(x['role'],x['region'])for x in reserved}:
        raise ValueError('photo_quality_output_roles_conflict')
    receipts=[]
    for item in reserved:
        key=(item['role'],item['region']);measured=expected[key];path=prepared['result']['photo_quality_images'][key]
        if any(item.get(k)!=measured[k] for k in ('bytes','sha256','width','height')):
            raise ValueError('photo_quality_output_measurement_conflict')
        etag=upload(item['put_url'],path,'image/jpeg',hosts,item['headers'],allow_existing=True)
        # Existing immutable PUT412 is not success authority. The Edge callback
        # independently HEADs/rehashes the reserved exact object before ready.
        row={k:item[k]for k in ('role','region','bucket','key','bytes','sha256','width','height','crop','mime')}
        if etag:row['etag']=etag
        receipts.append(row)
    return {'check_id':receipt['check_id'],'evidence_id':receipt['evidence_id'],'lease_token':receipt['lease_token'],'receipts':receipts}
