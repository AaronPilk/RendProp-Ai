"""Actual Python pipeline and server accounting, against an owned PG fixture only."""
from pathlib import Path
import concurrent.futures,copy,hashlib,io,json,os,subprocess,sys,unittest,urllib.error,uuid
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'services/pipeline'))
from providers import base,fal_client,funding
import router,cost_ledger
CFG=json.loads(Path(os.environ['PIPELINE_COST_PG_FIXTURE']).read_text())
RECORDS=[]
def lit(v):
 if v is None:return 'null'
 if isinstance(v,bool):return 'true'if v else 'false'
 if isinstance(v,(int,float)):return str(v)
 return "'"+str(v).replace("'","''")+"'"
def query(s,service=True,refusal=None):
 text=('begin;set local role service_role;'+s+';commit;')if service else s
 p=subprocess.run(CFG['psql']+['-c',text],env=CFG['env'],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=30)
 assert len(p.stdout)+len(p.stderr)<=1024**2,'Bounded fixture SQL output'
 if refusal:
  assert p.returncode!=0 and refusal in p.stderr.decode(),p.stderr.decode();return None
 if p.returncode:raise RuntimeError(p.stderr.decode())
 t=p.stdout.decode().strip();return json.loads(t)if t else None
RPCS={'serving_cost_reserve','serving_cost_finish','org_has_internal_testing_grant','org_has_private_internal_testing','pipeline_record_provider_cost'}
def rpc(name,args,refusal=None):
 assert name in RPCS,'Closed RPC allowlist'
 return query('select to_jsonb(public.'+name+'('+','.join(k+'=>'+(lit(json.dumps(v))+'::jsonb'if isinstance(v,dict)else lit(v))for k,v in args.items())+'))',refusal=refusal)
def scope():
 actor=str(uuid.uuid4());listing=str(uuid.uuid4());job=str(uuid.uuid4())
 query('insert into auth.users(id,email,is_anonymous)values('+lit(actor)+','+lit(actor+'@fixture.invalid')+',false)',False)
 org=query('select to_jsonb(org_id)from public.memberships where user_id='+lit(actor)+"and role='owner'",False)
 query('insert into public.listings(id,org_id,agent_id,address)values('+','.join(map(lit,[listing,org,actor,'Synthetic pipeline fixture']))+');insert into public.render_jobs(id,listing_id,status,source)values('+','.join(map(lit,[job,listing,'created','worker']))+')',False)
 return {'actor':actor,'org':org,'job':job,'listing':listing}
def reserve(c,bound=4,finish='uncertain'):
 digest='a'*64;stage='worker:'+digest[:48]
 a={'p_actor':c['actor'],'p_org':c['org'],'p_key':c['job'],'p_stage':stage,'p_provider':'fal','p_model':'fal-ai/flux-pro/kontext','p_input_sha256':digest,'p_hold_cents':bound,'p_tariff_version':funding.VERSION}
 got=rpc('serving_cost_reserve',a);token={'reservation_id':got['id'],'actor_id':c['actor'],'org_id':c['org'],'request_key':c['job'],'stage':stage,'provider':'fal','model':a['p_model'],'input_sha256':digest}
 if finish:finish_attempt(token,finish)
 return token
def finish_attempt(t,state='uncertain',refusal=None):
 return rpc('serving_cost_finish',{'p_actor':t['actor_id'],'p_org':t['org_id'],'p_key':t['request_key'],'p_stage':t['stage'],'p_state':state,'p_rejection_status':429 if state=='rejected'else None},refusal)
def cost_args(c,t,total=4):
 return {'p_actor':t['actor_id'],'p_org':t['org_id'],'p_reservation':t['reservation_id'],'p_key':t['request_key'],'p_stage':t['stage'],'p_provider':t['provider'],'p_model':t['model'],'p_input_sha256':t['input_sha256'],'p_job':c['job'],'p_feature':'restage','p_units':1,'p_unit_cost':total,'p_total':total,'p_meta':{'fallback':'flux_kontext','pipeline_funding':copy.deepcopy(t)}}
def state(c,start=None,end=None):
 return query("select jsonb_build_object('ledger_count',(select count(*)from public.cost_ledger where billing_org_id="+lit(c.get('payer',c['org']))+"),'ledger_cents',(select coalesce(sum(total_cents),0)from public.cost_ledger where billing_org_id="+lit(c.get('payer',c['org']))+"),'spent',public.serving_ceiling_spent_cents("+lit(c.get('payer',c['org']))+','+lit(start)+','+lit(end)+"),'holds',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'state',state,'bound',hold_cents,'payer',billing_org_id)),\'[]\')from public.serving_cost_reservations where org_id="+lit(c['org'])+"),'links',(select count(*)from public.pipeline_provider_cost_bindings b join public.serving_cost_reservations r on r.id=b.reservation_id where r.org_id="+lit(c['org'])+"))")
class Response:
 def __init__(self,data):self.data=data;self.status=200;self.headers={}
 def __enter__(self):return self
 def __exit__(self,*args):return False
 def read(self):return self.data
class PipelineCostTests(unittest.TestCase):
 def tearDown(self):
  if hasattr(self,'observation'):RECORDS.append({'case':self.id(),'observed':self.observation})
 def actual(self,c,lose_reply=False,provider_error=None):
  sent=[];lost=[False]
  def closed(req,timeout=None):
   url=req.full_url;method=req.get_method();sent.append({'method':method,'url':url})
   if method=='POST'and url=='https://queue.fal.run/fal-ai/flux-pro/kontext':
    if provider_error:raise urllib.error.HTTPError(url,provider_error,'synthetic',{},io.BytesIO(b'{}'))
    return Response(json.dumps({'images':[{'url':'https://synthetic.fixture.invalid/result.jpg'}],'request_id':'synthetic'}).encode())
   if method=='GET'and url=='https://synthetic.fixture.invalid/result.jpg':return Response(b'\xff\xd8\xffsynthetic-only')
   if method=='POST'and url=='https://closed.fixture.invalid/rest/v1/rpc/pipeline_record_provider_cost':
    saved=rpc('pipeline_record_provider_cost',json.loads(req.data))
    if lose_reply and not lost[0]:lost[0]=True;raise TimeoutError('Synthetic lost accounting reply AFTER commit')
    return Response(json.dumps(saved).encode())
   if method=='POST'and url=='https://closed.fixture.invalid/rest/v1/cost_ledger':
    row=json.loads(req.data);query('insert into public.cost_ledger('+','.join(row)+')values('+','.join(lit(json.dumps(v))+'::jsonb'if isinstance(v,dict)else lit(v)for v in row.values())+')');return Response(b'')
   if method=='GET'and url.startswith('https://closed.fixture.invalid/rest/v1/cost_ledger?select=total_cents&job_id=eq.'):
    return Response(json.dumps(query('select coalesce(jsonb_agg(jsonb_build_object(\'total_cents\',total_cents)),\'[]\')from public.cost_ledger where job_id='+lit(c['job']))).encode())
   if method=='PATCH'and url=='https://closed.fixture.invalid/rest/v1/render_jobs?id=eq.'+c['job']:
    query('update public.render_jobs set cost_cents='+str(json.loads(req.data)['cost_cents'])+' where id='+lit(c['job']));return Response(b'')
   raise AssertionError('Unexpected closed transport:'+method+' '+url)
  session=funding.ServingSession(c['actor'],c['org'],c['job'],rpc,lambda:None)
  ctx=router.JobContext(job_id=c['job'],org_id=c['org'],ledger=cost_ledger.CostLedger('https://closed.fixture.invalid','synthetic-only',False))
  with patch.object(fal_client,'_headers',lambda:{}),patch('urllib.request.urlopen',closed),patch('urllib.request.build_opener',lambda *a:type('Opener',(),{'open':staticmethod(closed)})()),funding.serving_session(session):
   if os.environ.get('PIPELINE_COST_FAULT')=='omit-python-binding':
    with patch.object(router,'result_funding',lambda *a:None):returned=router._meter(ctx,'restage',4,lambda:fal_client.restage_fallback_result(b'input','synthetic'))
   else:returned=router._meter(ctx,'restage',4,lambda:fal_client.restage_fallback_result(b'input','synthetic'))
   if lose_reply:ctx.ledger._insert_once(ctx.ledger.rows[0])
  return returned,ctx,sent
 def test_actual_pipeline_same_attempt_once(self):
  c=scope();data,ctx,sent=self.actual(c);s=state(c);self.observation=s
  self.assertEqual(s['spent'],4,'Pipeline same attempt counted twice')
  self.assertEqual(s['ledger_count'],1);self.assertEqual(s['links'],1);self.assertEqual(s['holds'][0]['state'],'uncertain');self.assertEqual(ctx.budget.spent_cents,4)
  self.assertTrue(data.data);self.assertEqual(sum(r['url'].startswith('https://queue.fal.run')for r in sent),1)
 def test_lost_accounting_reply_and_spool_replay_never_repeat_supplier(self):
  c=scope();_,ctx,sent=self.actual(c,True);s=state(c);self.observation=s
  self.assertEqual((s['ledger_count'],s['links'],s['spent']),(1,1,4));self.assertFalse(ctx.ledger.degraded)
  self.assertEqual(sum(r['url'].startswith('https://queue.fal.run')for r in sent),1)
 def test_bound_residual_and_larger_modeled_cost(self):
  results=[]
  for bound,cost,expected in [(20,4,20),(4,6,6),(4,0,4)]:
   c=scope();t=reserve(c,bound);rpc('pipeline_record_provider_cost',cost_args(c,t,cost));s=state(c);results.append(s)
   self.assertEqual(s['spent'],expected);self.assertEqual(s['holds'][0]['state'],'uncertain')
  self.observation=results
 def test_both_insert_finish_orders(self):
  out=[]
  for before in [True,False]:
   for final in ['uncertain','succeeded']:
    c=scope();t=reserve(c,20,final if before else None)
    rpc('pipeline_record_provider_cost',cost_args(c,t))
    if not before:finish_attempt(t,final)
    s=state(c);out.append(s);self.assertEqual(s['spent'],20);self.assertEqual(s['ledger_count'],1)
  self.observation=out
 def test_old_period_ledger_cannot_subtract_current_unknown_bound(self):
  c=scope();t=reserve(c,20);rpc('pipeline_record_provider_cost',cost_args(c,t))
  query('update public.cost_ledger set created_at=now()-interval\'2 months\' where idempotency_key='+lit('pipeline:'+t['reservation_id']),False)
  s=state(c,'2026-10-01T00:00:00Z','2026-11-01T00:00:00Z');self.observation=s;self.assertEqual(s['spent'],20)
 def test_concurrent_duplicate_costs_return_same_receipt(self):
  c=scope();t=reserve(c);args=cost_args(c,t)
  with concurrent.futures.ThreadPoolExecutor(max_workers=2)as pool:out=list(pool.map(lambda _:rpc('pipeline_record_provider_cost',args),range(2)))
  self.assertEqual(out[0],out[1]);s=state(c);self.observation=s;self.assertEqual((s['ledger_count'],s['links'],s['spent']),(1,1,4))
 def test_mismatched_attempt_actor_request_input_provider_and_payer_refuse(self):
  c=scope();t=reserve(c);args=cost_args(c,t)
  for key,value in [('p_actor',str(uuid.uuid4())),('p_org',str(uuid.uuid4())),('p_reservation',str(uuid.uuid4())),('p_provider','gemini'),('p_model','foreign'),('p_input_sha256','b'*64),('p_job',str(uuid.uuid4()))]:
   bad=copy.deepcopy(args);bad[key]=value
   with self.subTest(key=key):rpc('pipeline_record_provider_cost',bad,'RP4')
  bad=copy.deepcopy(args);bad['p_meta']['billing_org_id']=str(uuid.uuid4());rpc('pipeline_record_provider_cost',bad,'RP403')
  foreign=scope();bad=copy.deepcopy(args);bad['p_key']=foreign['job'];bad['p_job']=foreign['job'];rpc('pipeline_record_provider_cost',bad,'RP403')
  self.observation=state(c);self.assertEqual(self.observation['ledger_count'],0)
 def test_rejected_or_missing_attempt_cannot_create_a_cost(self):
  c=scope();t=reserve(c,finish='rejected');rpc('pipeline_record_provider_cost',cost_args(c,t),'RP403')
  self.assertEqual(state(c)['spent'],0);t['reservation_id']=str(uuid.uuid4());rpc('pipeline_record_provider_cost',cost_args(c,t),'RP403')
  self.observation=state(c);self.assertEqual(self.observation['ledger_count'],0)
 def test_recorded_cost_cannot_be_relabelled_definitive_rejection(self):
  c=scope();t=reserve(c,20,None);rpc('pipeline_record_provider_cost',cost_args(c,t));finish_attempt(t,'rejected','RP409')
  self.observation=state(c);self.assertEqual(self.observation['spent'],20);self.assertEqual(self.observation['holds'][0]['state'],'reserved')
 def test_failed_submit_keeps_unknown_liability_without_a_cost(self):
  c=scope()
  with self.assertRaises(base.ProviderError):self.actual(c,provider_error=500)
  self.observation=state(c);self.assertEqual((self.observation['spent'],self.observation['ledger_count'],self.observation['links']),(4,0,0));self.assertEqual(self.observation['holds'][0]['state'],'uncertain')
 def test_missing_session_or_unknown_unfunded_route_never_submits(self):
  c=scope()
  with patch.object(base.urllib.request,'urlopen')as send:
   with self.assertRaises(base.ProviderFundingError):base.request_json('https://queue.fal.run/fal-ai/flux-pro/kontext',payload={})
   with funding.serving_session(funding.ServingSession(c['actor'],c['org'],c['job'],rpc,lambda:None)):
    with self.assertRaises(base.ProviderFundingError):base.request_json('https://queue.fal.run/fal-ai/unpriced',payload={})
   send.assert_not_called()
  self.observation=state(c);self.assertEqual(self.observation['ledger_count'],0)
 def test_spoofed_existing_wrong_payer_row_is_not_acknowledged(self):
  c=scope();t=reserve(c);args=cost_args(c,t);foreign=scope();meta=args['p_meta']|{'pipeline_cost_protocol':'pipeline-cost-v1','pipeline_reservation_id':t['reservation_id'],'request_key':t['request_key'],'stage':t['stage'],'actor_id':t['actor_id'],'input_sha256':t['input_sha256'],'cost_basis':'pipeline_modeled_estimate','invoice_verified':False}
  # Adversarial historical-looking row, seeded only in this disposable database.
  query('alter table public.cost_ledger disable trigger z_team_billing_liability;insert into public.cost_ledger(job_id,org_id,billing_org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta,idempotency_key)values('+','.join(map(lit,[c['job'],c['org'],foreign['org'],'restage','fal',t['model'],1,4,4,json.dumps(meta),'pipeline:'+t['reservation_id']]))+');alter table public.cost_ledger enable trigger z_team_billing_liability',False)
  before=query('select to_jsonb(md5(row_to_json(l)::text))from public.cost_ledger l where idempotency_key='+lit('pipeline:'+t['reservation_id']))
  rpc('pipeline_record_provider_cost',args,'RP409')
  after=query('select to_jsonb(md5(row_to_json(l)::text))from public.cost_ledger l where idempotency_key='+lit('pipeline:'+t['reservation_id']))
  self.assertEqual(before,after);self.observation=state(c);self.assertEqual(self.observation['links'],0)

if __name__=='__main__':
 try:unittest.main()
 finally:
  target=Path(os.environ['PIPELINE_COST_CASE_EVIDENCE']);target.write_text(json.dumps(RECORDS,indent=2)+'\n')
