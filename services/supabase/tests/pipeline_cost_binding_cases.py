"""Actual Python pipeline and server accounting, against an owned PG fixture only."""
from pathlib import Path
import concurrent.futures,copy,datetime,hashlib,io,json,os,subprocess,sys,unittest,urllib.error,uuid
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
def month_window(offset_months=0):
 """UTC calendar-month [start,end) derived from the clock, never hardcoded."""
 first=datetime.datetime.now(datetime.timezone.utc).replace(day=1,hour=0,minute=0,second=0,microsecond=0)
 for _ in range(abs(offset_months)):first=(first-datetime.timedelta(days=1)).replace(day=1)if offset_months<0 else(first+datetime.timedelta(days=32)).replace(day=1)
 return first.isoformat(),(first+datetime.timedelta(days=32)).replace(day=1).isoformat()
TEAM_INVITE_ROLE='agent'
def team(owner_scope,agent_scope):
 """Bind agent_scope's private library to owner_scope's Team through the real invite RPCs."""
 code=uuid.uuid4().hex*2
 query("update public.orgs set plan='team',plan_source='manual' where id="+lit(owner_scope['org']),False)
 query('select public.create_org_invite('+','.join(map(lit,[owner_scope['actor'],owner_scope['org'],None,TEAM_INVITE_ROLE,code]))+')')
 query('select public.accept_org_invite('+lit(agent_scope['actor'])+','+lit(code)+')')
 assert query('select to_jsonb(public.library_billing_org('+lit(agent_scope['org'])+'))')==owner_scope['org'],'Team binding must make the owner org the payer'
def serving_mode(mode):
 query("update public.app_config set value=value||jsonb_build_object('mode',"+lit(mode)+") where key='serving_mode'",False)
 assert query('select to_jsonb(public.serving_mode())',False)==mode
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
 def actual(self,c,lose_reply=False,provider_error=None,sent=None):
  sent=[]if sent is None else sent;lost=[False]
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
  current=state(c,*month_window());older=state(c,*month_window(-2));self.observation={'current_month':current,'ledger_month':older}
  # The current period cannot be discounted by an older ledger row: the whole
  # 20-cent bound stays held. The ledger's own month counts it once (4) plus
  # the still-uncovered 16, never 24.
  self.assertEqual(current['spent'],20);self.assertEqual(older['spent'],20);self.assertEqual(older['ledger_cents'],4)
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
 def test_same_actor_same_library_other_request_cannot_borrow_the_attempt(self):
  # The existing foreign-request case changes the actor too. Here only the
  # request differs: same actor, same library, a second job of the same listing.
  c=scope();other=str(uuid.uuid4())
  query('insert into public.render_jobs(id,listing_id,status,source)values('+','.join(map(lit,[other,c['listing'],'created','worker']))+')',False)
  t=reserve(c);args=cost_args(c,t)
  for label,key,job,code in [('other request and job',other,other,'RP403'),('admitted key but other job',c['job'],other,'RP400'),('other key but admitted job',other,c['job'],'RP400')]:
   bad=copy.deepcopy(args);bad['p_key']=key;bad['p_job']=job
   with self.subTest(label=label):rpc('pipeline_record_provider_cost',bad,code)
  self.observation=state(c);self.assertEqual((self.observation['ledger_count'],self.observation['links'],self.observation['spent']),(0,0,4))
  self.assertEqual(self.observation['holds'][0]['state'],'uncertain')
 def test_stable_team_payer_is_the_admitted_parent(self):
  owner=scope();agent=scope();team(owner,agent);agent['payer']=owner['org']
  data,ctx,sent=self.actual(agent);s=state(agent);self.observation=s
  self.assertEqual((s['ledger_count'],s['ledger_cents'],s['links'],s['spent']),(1,4,1,4));self.assertEqual(s['holds'][0]['payer'],owner['org'])
  self.assertEqual(query('select to_jsonb(public.serving_ceiling_spent_cents('+lit(agent['org'])+',null,null))'),4,'the private library projects the same parent liability')
  self.assertEqual(query('select to_jsonb(billing_org_id)from public.cost_ledger where idempotency_key='+lit('pipeline:'+s['holds'][0]['id'])),owner['org'])
  self.assertEqual(sum(r['url'].startswith('https://queue.fal.run')for r in sent),1);self.assertEqual(ctx.budget.spent_cents,4)
 def test_in_flight_team_payer_removal_keeps_the_admitted_payer(self):
  owner=scope();agent=scope();team(owner,agent);t=reserve(agent,finish=None)
  self.assertEqual(query('select to_jsonb(billing_org_id)from public.serving_cost_reservations where id='+lit(t['reservation_id'])),owner['org'])
  # The real seat-removal trigger revokes the Team binding while the attempt is in flight.
  query('delete from public.memberships where org_id='+lit(owner['org'])+' and user_id='+lit(agent['actor']),False)
  self.assertEqual(query('select to_jsonb(public.library_billing_org('+lit(agent['org'])+'))'),agent['org'],'after removal the private library pays for itself')
  saved=rpc('pipeline_record_provider_cost',cost_args(agent,t));finish_attempt(t,'uncertain')
  self.assertEqual(saved['billing_org_id'],owner['org'],'the cost lands on the payer who admitted the attempt, never a newly selected one')
  parent=state({**agent,'payer':owner['org']});private=state(agent);self.observation={'parent':parent,'private':private}
  self.assertEqual((parent['ledger_count'],parent['ledger_cents'],parent['links'],parent['spent']),(1,4,1,4))
  self.assertEqual((private['ledger_count'],private['ledger_cents'],private['spent']),(0,0,0));self.assertEqual(private['holds'][0]['payer'],owner['org'])
 def test_funded_mode_without_funding_or_grant_never_submits_or_records(self):
  c=scope();serving_mode('funded')
  try:
   for name in ('org_has_internal_testing_grant','org_has_private_internal_testing'):self.assertIs(rpc(name,{'p_org':c['org']}),False)
   # The server refusal surfaces through the worker's rpc transport before any
   # supplier request; production's db._check raises the same way as this fixture.
   sent=[]
   with self.assertRaises(Exception)as refused:self.actual(c,sent=sent)
   self.assertIn('RP402: This workspace has no funded serving allowance',str(refused.exception));self.assertEqual(sent,[])
   a={'p_actor':c['actor'],'p_org':c['org'],'p_key':c['job'],'p_stage':'worker:'+'a'*48,'p_provider':'fal','p_model':'fal-ai/flux-pro/kontext','p_input_sha256':'a'*64,'p_hold_cents':4,'p_tariff_version':funding.VERSION}
   rpc('serving_cost_reserve',a,'RP402');a['p_tariff_version']='unpriced-private-sponsorship';rpc('serving_cost_reserve',a,'RP403')
  finally:serving_mode('ceiling')
  self.observation=state(c);self.assertEqual((self.observation['ledger_count'],self.observation['links'],self.observation['spent'],self.observation['holds']),(0,0,0,[]))
 def test_funded_slice_gross_hold_and_reserve_authority_unchanged(self):
  c=scope();serving_mode('funded')
  try:
   t0=datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=1);t1=t0+datetime.timedelta(days=31)
   components='{"storage":5,"delivery":5,"compute":5,"email":5,"support":5,"retention":5,"uncertainty":0}'
   got=query('select public.provision_serving_funding('+','.join(map(lit,[c['org'],'retail','synthetic-collection-'+c['org'],None,400,0,t0.isoformat(),t1.isoformat(),1,components,'b'*64]))+')')
   fund=got['funding_id'];t=reserve(c,finish=None)
   self.assertEqual(query('select to_jsonb(budget_source)from public.serving_cost_reservations where id='+lit(t['reservation_id'])),'funding')
   rpc('pipeline_record_provider_cost',cost_args(c,t));finish_attempt(t,'uncertain')
   gross=query('select to_jsonb(coalesce(sum(hold_cents),0))from public.serving_cost_reservations where funding_id='+lit(fund)+" and state<>'rejected'")
  finally:serving_mode('ceiling')
  s=state(c);self.observation={'slice_gross':gross,'state':s}
  # The funded-slice authority is the gross hold, unchanged by the binding; only the ceiling projection discounts.
  self.assertEqual((gross,s['ledger_count'],s['links']),(4,1,1))
  pins=query("select jsonb_build_object('reserve',(select md5(prosrc)from pg_proc where oid='public.serving_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,text)'::regprocedure),'trial',(select md5(prosrc)from pg_proc where oid='public.trial_sponsor_spent_cents()'::regprocedure),'envelope',(select md5(prosrc)from pg_proc where oid='public.library_serving_envelope_admit(uuid,uuid,numeric,text)'::regprocedure))",False)
  self.assertEqual(pins,{'reserve':'cb21cbb5723dbc3cddb6fa5d7b5a7895','trial':'69a9c6f22be06ded89cf6d9aaa82b1e6','envelope':'6aa21e77680f2e8f4b479b9a9b24fc7b'},'funded-slice, trial-gross and envelope authorities must be byte-identical to the launch head')
 def test_new_relation_and_rpc_are_service_only_and_unique(self):
  rel='public.pipeline_provider_cost_bindings';rec='public.pipeline_record_provider_cost(uuid,uuid,uuid,text,text,text,text,text,uuid,text,numeric,numeric,numeric,jsonb)';cov='public.pipeline_cost_covered_cents(uuid,timestamptz,timestamptz)'
  acl=query("select jsonb_build_object('anon_table',has_table_privilege('anon',"+lit(rel)+",'SELECT,INSERT,UPDATE,DELETE'),'authenticated_table',has_table_privilege('authenticated',"+lit(rel)+",'SELECT,INSERT,UPDATE,DELETE'),'service_write',has_table_privilege('service_role',"+lit(rel)+",'INSERT,UPDATE,DELETE'),'service_select',has_table_privilege('service_role',"+lit(rel)+",'SELECT'),'rls',(select relrowsecurity from pg_class where oid="+lit(rel)+"::regclass),'policies',(select count(*)from pg_policy where polrelid="+lit(rel)+"::regclass),'anon_rpc',has_function_privilege('anon',"+lit(rec)+",'execute')or has_function_privilege('anon',"+lit(cov)+",'execute'),'authenticated_rpc',has_function_privilege('authenticated',"+lit(rec)+",'execute')or has_function_privilege('authenticated',"+lit(cov)+",'execute'),'service_rpc',has_function_privilege('service_role',"+lit(rec)+",'execute')and has_function_privilege('service_role',"+lit(cov)+",'execute'),'definer',(select bool_and(prosecdef and proconfig=array['search_path=\"\"'])from pg_proc where oid in("+lit(rec)+"::regprocedure,"+lit(cov)+"::regprocedure)))",False)
  self.assertEqual(acl,{'anon_table':False,'authenticated_table':False,'service_write':False,'service_select':True,'rls':True,'policies':0,'anon_rpc':False,'authenticated_rpc':False,'service_rpc':True,'definer':True})
  c=scope();t=reserve(c);args=cost_args(c,t);call='select public.pipeline_record_provider_cost('+','.join(k+'=>'+(lit(json.dumps(v))+'::jsonb'if isinstance(v,dict)else lit(v))for k,v in args.items())+')'
  query('set role authenticated;'+call,False,'permission denied');query('set role anon;'+call,False,'permission denied')
  query(call,False,'insufficient_privilege')  # the migrating/owner role without the service role is refused too
  self.assertEqual(state(c)['ledger_count'],0)
  saved=rpc('pipeline_record_provider_cost',args);other=scope();u=reserve(other);second=rpc('pipeline_record_provider_cost',cost_args(other,u))
  query('insert into public.pipeline_provider_cost_bindings(reservation_id,ledger_id)values('+lit(u['reservation_id'])+','+lit(saved['ledger_id'])+')',refusal='permission denied')
  query('insert into public.pipeline_provider_cost_bindings(reservation_id,ledger_id)values('+lit(t['reservation_id'])+','+lit(second['ledger_id'])+')',False,'pipeline_provider_cost_bindings_pkey')
  query('insert into public.pipeline_provider_cost_bindings(reservation_id,ledger_id)values('+lit(str(uuid.uuid4()))+','+lit(saved['ledger_id'])+')',False,'pipeline_provider_cost_bindings_ledger_id_key')
  query('insert into public.pipeline_provider_cost_bindings(reservation_id,ledger_id)values('+lit(str(uuid.uuid4()))+','+lit(str(uuid.uuid4()))+')',False,'violates foreign key constraint')
  self.observation={'acl':acl,'first':state(c),'second':state(other)};self.assertEqual((self.observation['first']['links'],self.observation['second']['links']),(1,1))

if __name__=='__main__':
 try:unittest.main()
 finally:
  target=Path(os.environ['PIPELINE_COST_CASE_EVIDENCE']);target.write_text(json.dumps(RECORDS,indent=2)+'\n')
