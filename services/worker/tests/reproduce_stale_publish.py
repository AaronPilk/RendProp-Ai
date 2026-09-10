# Diagnostic: exits 1 while WH-03 is present. Loopback fake DB only.
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests'))
from test_job_lease import fresh_db, load_db_module, iso
import fake_postgrest
store = fresh_db()
server,url = fake_postgrest.start(store)
try:
    old_worker = load_db_module(url,worker_id='worker-A')
    store.tables['render_jobs'] = [{'id':'J1','status':'ready','worker_id':'worker-B','lease_expires_at':iso(60)}]
    store.tables['renders'] = [{'id':'R1','job_id':'J1','listing_id':'L1','slug':'kept',
                               'video_key':'worker-B-output.mp4'}]
    result = old_worker._replace_render_for_job({'job_id':'J1','video_key':'worker-A-stale.mp4'})
    print({'result_video_key':result['video_key'],'current_owner':store.tables['render_jobs'][0]['worker_id'],
           'current_status':store.tables['render_jobs'][0]['status']})
    if store.tables['renders'][0]['video_key'] != 'worker-B-output.mp4':
        raise AssertionError('stale publisher changed the newer owner output')
finally:
    server.shutdown()
    server.server_close()
