# Diagnostic: exits 1 while WH-04 is present. Prepares a 1 MiB request; never sends it.
import io
import requests
source = io.BytesIO(b'x' * (1024 * 1024))
prepared = requests.Request('POST','https://synthetic.invalid/stream',
                            files={'file':('synthetic.mp4',source,'video/mp4')}).prepare()
print({'source_bytes':1024*1024,'prepared_body_type':type(prepared.body).__name__,
       'prepared_body_bytes':len(prepared.body),'source_consumed':source.tell(),
       'network_requests':0})
if isinstance(prepared.body,bytes):
    raise AssertionError('multipart fallback buffers the full file before network transmission')
