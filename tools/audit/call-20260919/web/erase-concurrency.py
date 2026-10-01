#!/usr/bin/env python3
"""Actual parallel service RPC transactions against the caller's disposable PG.
Arguments are the owned psql connection command. Never reads credentials.
"""
import concurrent.futures,json,subprocess,sys,uuid
PSQL=sys.argv[1:]
assert PSQL and 'erase_audit' in PSQL, 'Only the disposable erase_audit database is allowed'
def sql(text,allow_error=False):
    p=subprocess.run([*PSQL,'-At','-c',text],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=25)
    if p.returncode and not allow_error:raise RuntimeError(p.stderr)
    return p.returncode,p.stdout.strip(),p.stderr.strip()
def parallel(queries):
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:return list(pool.map(lambda q:sql(q,True),queries))
def uid():return str(uuid.uuid4())
U,O,L,A,B,I=[uid() for _ in range(6)]
sql(f"""insert into auth.users(id,email) values('{U}','parallel-synthetic@example.invalid');
insert into orgs(id,name,plan) values('{O}','Disposable parallel erase test','pro');
insert into memberships(user_id,org_id,role) values('{U}','{O}','owner');
insert into listings(id,org_id,agent_id,address) values('{L}','{O}','{U}','Synthetic room');
update plan_entitlements set reels_per_month=100,cogs_ceiling_cents=5000 where plan='pro';
insert into capture_assets(id,listing_id,kind,storage_key,bucket,uploaded,duration_s) values('{A}','{L}','video','synthetic/parallel.mp4','renders',true,2);""")
def reserve(asset=A,batch=B,idem=I):return f"select video_erase_reserve('{O}','{U}','{L}','{batch}','{asset}','{idem}',repeat('a',64))"
results=parallel([reserve()]*8)
assert all(r[0]==0 for r in results),results
values=[json.loads(r[1]) for r in results];assert sum(v['dispatch'] for v in values)==1
J=values[0]['job']['id'];assert {v['job']['id'] for v in values}=={J}
assert sql(f"select count from rate_limits where key='reelmo:{O}'")[1]=='1'
REF=json.dumps({'request_id':'synthetic-confirmed','status_url':'https://queue.fal.run/bria/requests/synthetic-confirmed/status','response_url':'https://queue.fal.run/bria/requests/synthetic-confirmed'})
finish=f"select video_erase_finish('{J}','processing','{REF}'::jsonb)"
assert all(r[0]==0 for r in parallel([finish]*8))
assert sql(f"select count(*) from cost_ledger where org_id='{O}'")[1]=='1'
assert sql(f"select total_cents from cost_ledger where org_id='{O}'")[1] in ('28.0000','28.000000','28','28.00')
# Cancel and completion contend for the same org/job locks. Cancelled wins even
# if completion committed first because nothing has yet been accepted/applied.
cancel=f"select video_erase_cancel('{O}','{U}',null,'{B}')"
complete=f"select video_erase_finish('{J}','completed','{REF}'::jsonb,'https://media.invalid/result.mp4','synthetic/result.mp4')"
assert all(r[0]==0 for r in parallel([cancel,complete]*4))
assert sql(f"select state from video_erase_jobs where id='{J}'")[1]=='cancelled'
assert sql(f"select count from rate_limits where key='reelmo:{O}'")[1]=='0'
assert sql(f"select count(*) from cost_ledger where org_id='{O}'")[1]=='1'
# Four simultaneous4.8s jobs cannot overrun the240-cent batch hold: three fit.
B2=uid();assets=[uid() for _ in range(4)]
for a in assets:sql(f"insert into capture_assets(id,listing_id,kind,storage_key,bucket,uploaded,duration_s) values('{a}','{L}','video','synthetic/{a}.mp4','renders',true,4.8)")
results=parallel([reserve(a,B2,uid()) for a in assets]);assert sum(r[0]==0 for r in results)==3,results
assert all(r[0]==0 or 'RP402' in r[2] for r in results)
assert float(sql(f"select sum(cost_cents) from video_erase_jobs where batch_id='{B2}'")[1])==201.6
assert sql(f"select count from rate_limits where key='reelmo:{O}'")[1]=='3'
# A cancellation racing the FIRST reservation either prevents it outright or
# refunds that one receipt. Both orders end in the same tombstone and zero leak.
B3=uid();results=parallel([reserve(A,B3,uid()),f"select video_erase_cancel('{O}','{U}',null,'{B3}')"])
assert all(r[0]==0 or 'RP409' in r[2] for r in results),results
assert sql(f"select state from video_erase_batches where id='{B3}'")[1]=='cancelled'
assert sql(f"select count(*) from video_erase_jobs where batch_id='{B3}' and allowance_refunded_at is null")[1]=='0'
assert sql(f"select count from rate_limits where key='reelmo:{O}'")[1]=='3'
# Existing pipeline accounting and reflection holds use the same advisory lock.
sql("update plan_entitlements set cogs_ceiling_cents=100 where plan='pro'")
for attempt in range(8):
    co,cl,ca,cb,ci,cj=[uid() for _ in range(6)]
    sql(f"insert into orgs(id,name,plan) values('{co}','Cross-feature race','pro'); insert into memberships(user_id,org_id,role) values('{U}','{co}','owner'); insert into listings(id,org_id,agent_id,address) values('{cl}','{co}','{U}','Synthetic'); insert into capture_assets(id,listing_id,kind,storage_key,bucket,uploaded,duration_s) values('{ca}','{cl}','video','synthetic/{ca}.mp4','renders',true,4.8); insert into render_jobs(id,listing_id) values('{cj}','{cl}');")
    er=f"select video_erase_reserve('{co}','{U}','{cl}','{cb}','{ca}','{ci}',repeat('c',64))"
    other=f"select log_job_cost('{cj}','{co}','hero','fal','synthetic',1,50,'{{}}'::jsonb,2500)"
    raced=parallel([er,other]);assert sum(r[0]==0 for r in raced)==1,raced
    assert all(r[0]==0 or 'RP402' in r[2] for r in raced),raced
    assert float(sql(f"select org_month_spend_cents('{co}')")[1]) in (50,67.2)
print(json.dumps({'passed':True,'groups':6,'parallel_transactions':46,'checks':43,'cases':['8 concurrent duplicate reservations:one claim','8 receipt saves:one COGS row','cancel versus complete:cancelled once','4 batch reservations:201.6c/3 accepted','cancel before/after first reserve:no allowance leak','8 reflection-versus-log_job_cost races:one winner under100c']}))
