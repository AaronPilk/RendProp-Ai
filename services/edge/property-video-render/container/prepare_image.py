"""Owned master -> private video workingcopy. Original bytes are untouched.

Orientation is baked into pixels, embedded ICC is converted to sRGB, and private
EXIF/GPS is removed. Provider inputs are bounded2048px JPEGs; real-photo fallback
uses a separate lossless full-resolution workingcopy without that resize.
"""
import io
import warnings
from pathlib import Path
from PIL import Image, ImageCms, ImageOps
from capabilities import digest, download

MAX_SOURCE_BYTES = 50 * 1024 * 1024
MAX_PIXELS = 100_000_000
MAX_EDGE = 2048
MAX_OUTPUT_BYTES = 8 * 1024 * 1024
POLICY = 'video-jpeg-v1'
Image.MAX_IMAGE_PIXELS = MAX_PIXELS


def decoded_srgb(source):
    """Shared actual decode/orientation/color admission for both workingcopies."""
    with warnings.catch_warnings():
        warnings.simplefilter('error', Image.DecompressionBombWarning)
        try:
            raw = Image.open(source, formats=('JPEG', 'PNG', 'WEBP'))
        except Image.UnidentifiedImageError as error:
            raise ValueError('single_supported_photo_required') from error
        with raw:
            if raw.format not in {'JPEG', 'PNG', 'WEBP'} or getattr(raw, 'n_frames', 1) != 1:
                raise ValueError('single_supported_photo_required')
            if raw.width < 1 or raw.height < 1 or raw.width * raw.height > MAX_PIXELS:
                raise ValueError('bounded_photo_pixels_required')
            raw.load()
            image = ImageOps.exif_transpose(raw)
            profile = image.info.get('icc_profile')
            srgb = ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB'))
            alpha = image.getchannel('A') if 'A' in image.getbands() else image.convert('RGBA').getchannel('A') if 'transparency' in image.info else None
            if profile:
                if not isinstance(profile, bytes) or not 1 <= len(profile) <= 1024 * 1024:
                    raise ValueError('bounded_color_profile_required')
                try:
                    origin = ImageCms.ImageCmsProfile(io.BytesIO(profile))
                    color = image.convert('RGB') if image.mode in {'RGBA', 'P', 'LA'} else image
                    image = ImageCms.profileToProfile(color, origin, srgb, outputMode='RGB')
                except (ValueError, TypeError, OSError, ImageCms.PyCMSError) as error:
                    raise ValueError('photo_color_profile_refused') from error
            elif image.mode in {'CMYK', 'LAB', 'I', 'F', 'I;16'}:
                raise ValueError('explicit_photo_color_profile_required')
            else:
                image = image.convert('RGB')
            if alpha is not None:
                background = Image.new('RGB', image.size, 'white')
                background.paste(image, mask=alpha)
                image = background
            return image.copy(), srgb.tobytes()


def normalize(source, target):
    """Measured provider JPEG. Never modifies the original source file."""
    image, profile = decoded_srgb(source)
    oriented_size = image.size
    image.thumbnail((MAX_EDGE, MAX_EDGE), Image.Resampling.LANCZOS)
    # Fixed q97 keeps quality stable. Very noisy images reduce geometry,
    # rather than dropping encoder quality or exceeding provider bounds.
    for _ in range(8):
        image.save(target, 'JPEG', quality=97, subsampling=0, optimize=True, icc_profile=profile)
        if Path(target).stat().st_size <= MAX_OUTPUT_BYTES:
            break
        image = image.resize((max(1, round(image.width*.9)), max(1, round(image.height*.9))), Image.Resampling.LANCZOS)
    else:
        raise ValueError('bounded_prepared_photo_required')
    with Image.open(target) as check:
        check.load()
        if check.format != 'JPEG' or check.mode != 'RGB' or check.size != image.size or check.getexif().get(274) is not None:
            raise ValueError('prepared_photo_decode_conflict')
    return {'width':image.width, 'height':image.height,
            'source_width':oriented_size[0], 'source_height':oriented_size[1]}


def normalize_full_resolution(source, target):
    """Lossless full-pixel RGB PNG for real-photo motion, no2048px resize."""
    image, profile = decoded_srgb(source)
    # Re-encoding these already decoded RGB pixels losslessly avoids a second
    # JPEG quantization step before H264. Metadata cannot re-rotate the frame.
    image.save(target, 'PNG', compress_level=1, icc_profile=profile)
    if not 1 <= Path(target).stat().st_size <= 512 * 1024 * 1024:
        raise ValueError('bounded_full_resolution_copy_required')
    with Image.open(target) as check:
        check.load()
        if check.format != 'PNG' or check.mode != 'RGB' or check.size != image.size or check.getexif():
            raise ValueError('full_resolution_copy_decode_conflict')
    return {'width':image.width, 'height':image.height}


def prepare_image(task, directory, hosts):
    original, prepared = directory/'source-master', directory/'prepared.jpg'
    source_sha = download(task['source'], original, hosts, max_bytes=MAX_SOURCE_BYTES)
    dimensions = normalize(original, prepared)
    original.unlink()
    receipt = {'job_id':task['job_id'], 'lease_token':task['lease_token'],
               'source_sha256':source_sha, 'asset_id':task['output']['asset_id'],
               'bytes':prepared.stat().st_size, 'sha256':digest(prepared),
               'width':dimensions['width'], 'height':dimensions['height'], 'mime':'image/jpeg'}
    return {'receipt':receipt, 'prepared_image':prepared}
