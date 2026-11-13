#!/usr/bin/env python3
"""Exercise guarded historical SQL handoffs in owned Postgres.

The cluster uses a private Unix socket and is stopped even when a migration fails.
No configured Supabase database or inherited PostgreSQL connection is used.
"""

import argparse
import concurrent.futures
from datetime import datetime, timezone
import hashlib
import json
import os
import re
import threading
import time
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS = ROOT / "services/supabase/migrations"
AERIAL = "20261022223138_aerial_opening_photo_motion_composition_20261022.sql"
HISTORY = "20261022223142_photo_motion_preserve_exact_producer_history_20261022.sql"
LIVE_ADOPTION = "20261023044520_photo_motion_bfb1_fixed_recovery_controller.sql"
PHOTO_PUBLICATION = "20261020212328_accepted_photo_publication_host_compatible.sql"
PREDECESSOR_MD5 = "28867ce20c2e3d208c78083f4a232376"
HISTORY_MD5 = "c29019ad250ba607244137d0e2140719"
ADMISSION_MD5 = "208841bb1ad938ce350f523db1287e3b"
PUBLICATION_MD5 = "56b0bd247ea9461c5a71ce5a3cab46cf"


def run(argv, env, *, ok=True):
    result = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True, text=True, timeout=300)
    if (result.returncode == 0) != ok:
        raise AssertionError(f"{Path(argv[0]).name} exited {result.returncode}: {result.stderr[-3000:]}")
    return result


def psql(env, sql, *, database="rendprop", ok=True):
    return run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-d", database, "-c", sql], env, ok=ok)


def apply(env, path, *, database="rendprop", ok=True):
    return run(["psql", "-X", "-q", "-1", "-v", "ON_ERROR_STOP=1", "-d", database, "-f", str(path)], env, ok=ok)


def assert_handoff(env, body_md5, *, renamed):
    name = ("property_video_photo_motion_saved_identity_before_opening_20261022"
            if renamed else "property_video_photo_motion_saved_identity")
    psql(env, f"""
do $verify$begin
 if not exists(select 1 from pg_proc
   where oid=to_regprocedure('public.{name}(text,jsonb)')
     and md5(prosrc)='{body_md5}' and prosecdef and provolatile='s'
     and proconfig=ARRAY['search_path=""']::text[]
     and pg_get_userbyid(proowner)='postgres' and proacl::text='{{postgres=X/postgres}}')
 then raise exception 'Photo motion predecessor body or private authority changed';end if;
 if public.{name}('unsupported','{{}}'::jsonb)
    or public.{name}('photo-motion-v2-cfr24','{{}}'::jsonb)
 then raise exception 'Photo motion predecessor accepted an unsaved identity';end if;
end$verify$;
""")


# The current-controller phase is deliberately opt-in. Historical no-argument
# semantics above/below remain valid; CI must pass all three immutable inputs.
CF7_MIGRATION = '20261023185845_photo_motion_cf7_concurrent_scheduler_history_20261023.sql'
CF7_MIGRATION_SHA256 = '13456ba634895717892380a556f51b734e394df1381d43cbd51c0dd065494c9a'
CF7_CONTROLLER = 'cf7a8a05bbebe9d60d6b366ed1fbe926380cefcdf258771ae59081a29e587d64'
CF7_SIGNATURES = (
    'public.property_video_photo_motion_saved_identity_before_opening_20261(text,jsonb)',
    'public.property_video_photo_motion_saved_identity(text,jsonb)',
)
CF7_BODY_MD5 = ('8365ad4595cb841751ac8a37814a01e8', 'c71cb0a50f5e0920fdf80c0a5bad2233')


def sql_literal(value):
    return "'" + value.replace("'", "''") + "'"


def cf7_predecessor():
    """Independent seed from reviewed historical poststate, never candidate SQL."""
    source = (MIGRATIONS / CF7_MIGRATION).read_bytes()
    if hashlib.sha256(source).hexdigest() != CF7_MIGRATION_SHA256:
        raise AssertionError('Historical cf7 source changed')
    source = source.decode()
    definitions, identities = [], []
    for index, expected in enumerate(CF7_BODY_MD5):
        matches = re.findall(r'EXECUTE \$definition' + str(index) + r'\$([\s\S]*?)\$definition' + str(index) + r'\$', source)
        if len(matches) != 1:
            raise AssertionError('Historical cf7 definition extraction is not unique')
        definition = matches[0]
        body = re.search(r'AS \$function\$([\s\S]*?)\$function\$', definition).group(1)
        if hashlib.md5(body.encode()).hexdigest() != expected:
            raise AssertionError('Historical cf7 poststate body changed')
        literals = [json.loads(raw) for raw in re.findall(r"'([^']+)'::jsonb", body)]
        if len(literals) != (7, 5)[index] or any('producer_identity' not in item for item in literals):
            raise AssertionError('Historical producer inventory changed')
        definitions.append(definition)
        identities.append(literals)
    configs = json.loads(re.search(r'\$configs\$([\s\S]*?)\$configs\$', source).group(1))
    for item in configs:
        item['value']['producer_identity']['controller_sha256'] = CF7_CONTROLLER
    if {item['key'] for item in configs} != {
            'photo_motion_renderer_v2', 'photo_motion_renderer_v2_opening', 'property_video_aerial_opening'}:
        raise AssertionError('Historical producer configuration inventory changed')
    return definitions, identities, configs


def adoption_expectations(module_sha256):
    definitions, histories, configs = cf7_predecessor()
    result = []
    for definition, history in zip(definitions, histories):
        latest = [identity for identity in history
                  if identity['producer_identity']['controller_sha256'] == CF7_CONTROLLER]
        if len(latest) != 1:
            raise AssertionError('cf7 tuple is not unique')
        old = latest[0]
        new = json.loads(json.dumps(old))
        new['producer_identity']['controller_sha256'] = module_sha256
        # Match the exact literal bytes, not a broad replacement of old history.
        raw = next(raw for raw in re.findall(r"'([^']+)'::jsonb", definition) if json.loads(raw) == old)
        anchor = sql_literal(raw) + '::jsonb'
        new_raw = json.dumps(new, sort_keys=True, separators=(',', ':'))
        if definition.count(anchor) != 1:
            raise AssertionError('cf7 full identity anchor is not unique')
        new_definition = definition.replace(anchor, anchor + '\n     or p_identity is not distinct from ' + sql_literal(new_raw) + '::jsonb')
        body = re.search(r'AS \$function\$([\s\S]*?)\$function\$', new_definition).group(1)
        result.append({'definition': new_definition, 'body_md5': hashlib.md5(body.encode()).hexdigest(),
                       'identity': new, 'history': history})
    return result, configs


def query_json(env, sql, database):
    result = run(['psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', database, '-c', sql], env)
    return json.loads(result.stdout)


def catalog_snapshot(env, database):
    signatures = ','.join(sql_literal(signature) for signature in CF7_SIGNATURES)
    return query_json(env, f"""select jsonb_build_object(
      'functions',(select jsonb_object_agg(signature,jsonb_build_object(
          'catalog',to_jsonb(p),'definition',pg_get_functiondef(p.oid),
          'comment',obj_description(p.oid,'pg_proc')))
        from unnest(array[{signatures}])signature join pg_proc p on p.oid=to_regprocedure(signature)),
      'configs',(select jsonb_object_agg(key,to_jsonb(c)) from public.app_config c))""", database)


def data_snapshot(env, database):
    # Include nonempty synthetic jobs, source receipts, quote and held cost row.
    # Every public ordinary table except app_config must be byte-equivalent.
    tables = query_json(env, "select coalesce(jsonb_agg(tablename order by tablename),'[]') from pg_tables where schemaname='public' and tablename<>'app_config'", database)
    statements = []
    for table in tables:
        identifier = '"' + table.replace('"', '""') + '"'
        statements.append(f"select {sql_literal(table)} name,jsonb_build_object('count',count(*),'sha256',encode(sha256(convert_to(coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text),'[]'::jsonb)::text,'UTF8')),'hex')) value from public.{identifier} t")
    return query_json(env, 'select jsonb_object_agg(name,value) from ('+' union all '.join(statements)+') snapshots', database)


def seed_cf7(env, database):
    definitions, histories, configs = cf7_predecessor()
    for signature, definition in zip(CF7_SIGNATURES, definitions):
        psql(env, definition + ';\n' + f"alter function {signature} owner to postgres; revoke all on function {signature} from public,anon,authenticated,service_role; grant execute on function {signature} to postgres; comment on function {signature} is 'synthetic cf7 predecessor preservation witness';", database=database)
    for item in configs:
        psql(env, f"insert into public.app_config(key,value) values({sql_literal(item['key'])},{sql_literal(json.dumps(item['value']))}::jsonb) on conflict(key) do update set value=excluded.value", database=database)
    observed = catalog_snapshot(env, database)
    for index, signature in enumerate(CF7_SIGNATURES):
        function = observed['functions'][signature]
        catalog = function['catalog']
        if hashlib.md5(catalog['prosrc'].encode()).hexdigest() != CF7_BODY_MD5[index]:
            raise AssertionError('Independent cf7 seed did not reconstruct live body')
        if catalog['proconfig'] != ['search_path=""'] or not catalog['prosecdef'] or catalog['provolatile'] != 's':
            raise AssertionError('Independent cf7 seed lost private stable authority')
    # Fixture transport only: avoid account/provider/funding admissions while
    # inserting guard witnesses. CHECK constraints stay enabled. Normal trigger
    # execution is restored before any adoption SQL is applied.
    psql(env, """
set session_replication_role=replica;
insert into public.property_video_jobs(id,operation_id,actor_id,listing_id,org_id,library_org_id,
 manifest,manifest_sha256,source_count,state,consent_revision,quality_profile,audio_lease,audio_attempts,compose_lease,compose_attempts,result)
select ('81000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,gen_random_uuid(),
 '82000000-0000-4000-8000-000000000001','82000000-0000-4000-8000-000000000002',
 '82000000-0000-4000-8000-000000000003','82000000-0000-4000-8000-000000000003',
 '{"source_mode":"photo_motion_v1","synthetic_receipt":"retain-exact-inputs"}',repeat('a',64),1,state,
 'photo-motion-v1','photo-motion-v2-cfr24',gen_random_uuid(),1,gen_random_uuid(),1,
 '{"synthetic_paid_result":"retained"}' from (values(1,'ready'),(2,'failed'),(3,'cancelled'))v(n,state);
insert into public.property_video_job_sources(job_id,position,photo_id,asset_id,version_id,source,motion,state,receipt,clip)
values('81000000-0000-4000-8000-000000000001',0,'synthetic-retained-photo',
 '82000000-0000-4000-8000-000000000004','synthetic-version','{"sha256":"synthetic-source-witness"}',
 'push_in','ready','{"synthetic_provider_receipt":"unchanged"}','{"synthetic_clip":"unchanged"}');
insert into public.property_video_aerial_openings(id,operation_id,actor_id,org_id,billing_org_id,policy,library_org_id,listing_id,
 manifest,manifest_sha256,original_source,quote,consent,state,input_lease,input_claimed_at,qualification_lease,qualification_claimed_at,provider_receipt)
select ('83000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,gen_random_uuid(),
 '82000000-0000-4000-8000-000000000001','82000000-0000-4000-8000-000000000003',
 '82000000-0000-4000-8000-000000000003','{"synthetic_policy":"unchanged"}',
 '82000000-0000-4000-8000-000000000003','82000000-0000-4000-8000-000000000002',
 '{"synthetic_manifest":"unchanged"}',repeat('b',64),'{"synthetic_original":"unchanged"}',
 '{"synthetic_quote_cents":67}','{"synthetic_consent":"unchanged"}',state,
 gen_random_uuid(),now()-interval '2 hours',gen_random_uuid(),now()-interval '1 hour',
 '{"synthetic_provider_receipt":"unchanged"}' from (values(1,'failed'),(2,'ready_for_acceptance'),(3,'accepted'))v(n,state);
insert into public.app_video_cost_reservations(org_id,actor_id,idempotency_key,feature,provider,model,input_sha256,units,unit_cost_cents,total_cents,hold_cents,meta)
values('82000000-0000-4000-8000-000000000003','82000000-0000-4000-8000-000000000001',
 'synthetic-adoption-held-cost','aerial','kie','synthetic-model',repeat('c',64),1,67,67,70,'{"synthetic_hold":"not-dispatched"}');
set session_replication_role=origin;
""", database=database)
    # Immutable admitted producer witnesses, not merely a source_mode marker.
    ordinary = next(identity for identity in histories[0]
                    if identity['producer_identity']['controller_sha256']==CF7_CONTROLLER)
    aerial = next(item['value'] for item in configs if item['key']=='property_video_aerial_opening')
    psql(env, 'set session_replication_role=replica; update public.property_video_jobs set quality_identity='+sql_literal(json.dumps(ordinary))+"::jsonb; update public.property_video_aerial_openings set policy="+sql_literal(json.dumps(aerial))+"::jsonb; set session_replication_role=origin;", database=database)
    return histories


def assert_identities(env, database, expectations, *, adopted):
    assertions = []
    for signature, expected in zip(CF7_SIGNATURES, expectations):
        function = signature.split('(')[0]
        profile = expected['identity']['composition_profile']
        for identity in expected['history'] + ([expected['identity']] if adopted else []):
            assertions.append(f"if not {function}({sql_literal(profile)},{sql_literal(json.dumps(identity))}::jsonb) then raise exception 'Saved exact producer history was lost';end if;")
        if not adopted:
            assertions.append(f"if {function}({sql_literal(profile)},{sql_literal(json.dumps(expected['identity']))}::jsonb) then raise exception 'Unadopted producer was already accepted';end if;")
        invalids = [None, {}, {**expected['identity'], 'unexpected': True}]
        for field, value in [('fps',30), ('max_compose_attempts',4), ('max_audio_attempts',4),
                             ('max_processing_wall_ms',1260001), ('rate_evidence_sha256','0'*64),
                             ('composition_profile','unsupported'), ('transition','crossfade')]:
            invalids.append({**expected['identity'], field:value})
        for field, value in [('controller_sha256','0'*64), ('renderer_source_sha256','0'*64),
                             ('image_uri','registry.invalid/foreign@sha256:'+'0'*64)]:
            invalids.append({**expected['identity'], 'producer_identity':{**expected['identity']['producer_identity'],field:value}})
        missing = dict(expected['identity']); missing.pop('rate_evidence_sha256'); invalids.append(missing)
        for identity in invalids:
            assertions.append(f"if {function}({sql_literal(profile)},{sql_literal(json.dumps(identity))}::jsonb) then raise exception 'Unsaved producer shape was accepted';end if;")
        assertions.append(f"if {function}('unsupported',{sql_literal(json.dumps(expected['identity']))}::jsonb) then raise exception 'Cross-profile producer was accepted';end if;")
    psql(env, 'do $verify$begin\n'+'\n'.join(assertions)+'\nend$verify$;', database=database)
    return len(assertions)


def run_current_adoption(env, socket, args):
    from run_database_regression import partition_fresh_migrations
    started_at = datetime.now(timezone.utc).isoformat()
    candidate = args.adoption_sql.resolve()
    candidate_bytes = candidate.read_bytes()
    if hashlib.sha256(candidate_bytes).hexdigest() != args.adoption_sql_sha256:
        raise AssertionError('Candidate adoption SQL bytes changed')
    expectations, configs = adoption_expectations(args.module_sha256)
    input_paths = sorted(MIGRATIONS.glob('*.sql')) + [Path(__file__), ROOT/'tools/audit/run_database_regression.py']
    input_hashes = {str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in input_paths}
    phase_checks = []
    refusal_evidence = []
    def candidate_result(database):
        return subprocess.run(['psql','-X','-q','-1','-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose',
                               '-d',database,'-f',str(candidate)],cwd=ROOT,env=env,
                              capture_output=True,text=True,timeout=300)
    def known_busy_refusal(result):
        # Exact PostgreSQL55P03 on only our two relation fences or config rows.
        # No timeout, deadlock, arbitrary nonzero or unrelated55P03 is accepted.
        match = re.search(r'ERROR:\s+55P03:\s+(could not obtain lock on relation "(?:public\.)?(?:property_video_jobs|property_video_aerial_openings)"|could not obtain lock on row in relation "(?:public\.)?app_config")(?:\r?\n|$)',result.stderr)
        return match.group(1).replace('relation "public.', 'relation "') if result.returncode!=0 and match else None
    def clone(name, template):
        run(['createdb','-h',str(socket),'-U','postgres','--template='+template,name],env)
    def unchanged_refusal(database, marker, *, busy=False):
        before = (catalog_snapshot(env,database),data_snapshot(env,database))
        refused = candidate_result(database)
        matches = known_busy_refusal(refused)==marker if busy else marker in refused.stderr
        if refused.returncode==0 or not matches:
            raise AssertionError('Adoption refusal did not reach expected guard: '+refused.stderr[-2000:])
        if before != (catalog_snapshot(env,database),data_snapshot(env,database)):
            raise AssertionError('Refused adoption changed catalog/config/data')
        phase_checks.append(marker)
        refusal_evidence.append({'database':database,'expected':marker,'known_busy_target':known_busy_refusal(refused),
                                 'stderr_tail':refused.stderr[-2000:]})
    run(['createdb','-h',str(socket),'-U','postgres','adoption_schema'],env)
    apply(env,ROOT/'services/supabase/tests/ci-bootstrap.sql',database='adoption_schema')
    schema,_ = partition_fresh_migrations(sorted(MIGRATIONS.glob('*.sql')))
    if candidate.name in {path.name for path in schema}:
        raise AssertionError('Candidate live adoption must be classified, never fresh schema SQL')
    for path in schema:
        apply(env,path,database='adoption_schema')
    unchanged_refusal('adoption_schema','Controller adoption: function predecessor changed:')
    clone('adoption_cf7','adoption_schema')
    seed_cf7(env,'adoption_cf7')
    count = assert_identities(env,'adoption_cf7',expectations,adopted=False)
    baseline = catalog_snapshot(env,'adoption_cf7')
    for index,signature in enumerate(CF7_SIGNATURES):
        alterations = [
            baseline['functions'][signature]['definition'].replace('AS $function$','AS $function$\n-- synthetic changed predecessor\n',1),
            f'grant execute on function {signature} to anon',
            f'alter function {signature} owner to service_role',
            f'alter function {signature} set search_path=public',
        ]
        for mutation,sql in enumerate(alterations):
            database=f'adoption_function_{index}_{mutation}';clone(database,'adoption_cf7')
            psql(env,sql,database=database)
            unchanged_refusal(database,'Controller adoption: function predecessor changed: '+signature)
    for index,item in enumerate(configs):
        for mutation,sql in enumerate([
            f"delete from public.app_config where key={sql_literal(item['key'])}",
            f"update public.app_config set value=jsonb_set(value,'{{enabled}}','false'::jsonb) where key={sql_literal(item['key'])}",
            f"update public.app_config set value=jsonb_set(value,'{{producer_identity,controller_sha256}}',to_jsonb(repeat('0',64)),false) where key={sql_literal(item['key'])}",
        ]):
            database=f'adoption_config_{index}_{mutation}';clone(database,'adoption_cf7')
            psql(env,sql,database=database)
            unchanged_refusal(database,'Controller adoption: config predecessor changed: '+item['key'])
    # Expired leases remain evidence of unresolved work. Attempts without a
    # current lease and claimed timestamps without a token also refuse.
    for index,assignment in enumerate([
        "audio_lease=gen_random_uuid(),audio_until=now()-interval '1 day',audio_attempts=0,compose_lease=null,compose_attempts=0",
        'audio_lease=null,audio_attempts=1,compose_lease=null,compose_attempts=0',
        "audio_lease=null,audio_attempts=0,compose_lease=gen_random_uuid(),compose_until=now()-interval '1 day',compose_attempts=0",
        'audio_lease=null,audio_attempts=0,compose_lease=null,compose_attempts=1',
    ]):
        database=f'adoption_pm_work_{index}';clone(database,'adoption_cf7')
        psql(env,"set session_replication_role=replica; update public.property_video_jobs set state='queued',"+assignment+" where id='81000000-0000-4000-8000-000000000002'; set session_replication_role=origin;",database=database)
        unchanged_refusal(database,'Controller adoption: unresolved PM work exists')
    for index,assignment in enumerate([
        "input_lease=gen_random_uuid(),input_lease_until=now()-interval '1 day',input_claimed_at=null,qualification_lease=null,qualification_claimed_at=null",
        'input_lease=null,input_claimed_at=now(),qualification_lease=null,qualification_claimed_at=null',
        "input_lease=null,input_claimed_at=null,qualification_lease=gen_random_uuid(),qualification_lease_until=now()-interval '1 day',qualification_claimed_at=null",
        'input_lease=null,input_claimed_at=null,qualification_lease=null,qualification_claimed_at=now()',
    ]):
        database=f'adoption_aerial_work_{index}';clone(database,'adoption_cf7')
        psql(env,"set session_replication_role=replica; update public.property_video_aerial_openings set state='preparing_input',"+assignment+" where id='83000000-0000-4000-8000-000000000001'; set session_replication_role=origin;",database=database)
        unchanged_refusal(database,'Controller adoption: unresolved aerial work exists')
    clone('adoption_pm_queued','adoption_cf7')
    psql(env,"set session_replication_role=replica; update public.property_video_jobs set state='queued',audio_lease=null,audio_attempts=0,compose_lease=null,compose_attempts=0 where id='81000000-0000-4000-8000-000000000002'; set session_replication_role=origin;",database='adoption_pm_queued')
    queued=query_json(env,"select jsonb_build_object('producer',quality_identity->'producer_identity','no_cpu',audio_lease is null and compose_lease is null and audio_attempts=0 and compose_attempts=0) from public.property_video_jobs where id='81000000-0000-4000-8000-000000000002'",'adoption_pm_queued')
    if not queued['no_cpu'] or queued['producer']!=expectations[0]['history'][-1]['producer_identity']:
        raise AssertionError('Queued PM witness does not carry exact old immutable producer with zero CPU work')
    unchanged_refusal('adoption_pm_queued','Controller adoption: unresolved PM work exists')
    clone('adoption_aerial_queued','adoption_cf7')
    psql(env,"set session_replication_role=replica; update public.property_video_aerial_openings set state='queued_input',input_lease=null,input_claimed_at=null,qualification_lease=null,qualification_claimed_at=null,provider_receipt=null where id='83000000-0000-4000-8000-000000000001'; set session_replication_role=origin;",database='adoption_aerial_queued')
    queued=query_json(env,"select jsonb_build_object('producer',policy->'producer_identity','no_cpu',input_lease is null and input_claimed_at is null and qualification_lease is null and qualification_claimed_at is null) from public.property_video_aerial_openings where id='83000000-0000-4000-8000-000000000001'",'adoption_aerial_queued')
    if not queued['no_cpu'] or queued['producer']!=expectations[0]['history'][-1]['producer_identity']:
        raise AssertionError('Queued aerial witness does not carry exact old immutable producer with zero CPU work')
    unchanged_refusal('adoption_aerial_queued','Controller adoption: unresolved aerial work exists')
    # Own only synthetic processes in this private cluster/database. Confirm
    # actual granted/waiting PostgreSQL locks before exercising each fence.
    def start_holder(database, name, sql):
        return subprocess.Popen(['psql','-X','-q','-v','ON_ERROR_STOP=1','-d',database,'-c',sql],
            cwd=ROOT,env={**env,'PGAPPNAME':name},stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    def wait_holder(database, name, lock_predicate, process):
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            pids=query_json(env,"select coalesce(jsonb_agg(distinct a.pid),'[]') from pg_stat_activity a join pg_locks l on l.pid=a.pid where a.application_name="+sql_literal(name)+" and a.datname="+sql_literal(database)+" and ("+lock_predicate+")",database)
            if len(pids)==1:return int(pids[0])
            if process.poll() is not None:raise AssertionError('Owned lock holder exited before fence test')
            time.sleep(.02)
        raise AssertionError('Owned holder did not reach the intended PostgreSQL lock')
    def stop_holder(database, name, process):
        psql(env,"select pg_terminate_backend(pid) from pg_stat_activity where application_name="+sql_literal(name)+" and datname="+sql_literal(database),database=database)
        process.communicate(timeout=5)
    def assert_relations_released(database):
        # Both fences must be obtainable while the unrelated blocker still
        # exists. This detects partial acquisition leaking past failed adoption.
        psql(env,"begin; lock table public.property_video_jobs,public.property_video_aerial_openings in access exclusive mode nowait; rollback;",database=database)
    clone('adoption_slot_busy','adoption_cf7')
    name='synthetic-adoption-slot-holder';database='adoption_slot_busy'
    holder=start_holder(database,name,"begin; select pg_advisory_xact_lock(hashtextextended('property-video-photo-motion-slot-0',79)); select pg_sleep(30); rollback;")
    try:
        wait_holder(database,name,"l.locktype='advisory' and l.granted",holder)
        unchanged_refusal(database,'Controller adoption: Photo Motion slot is busy')
        assert_relations_released(database)
    finally:stop_holder(database,name,holder)
    # The aerial claimant owns an actual aerial row/table lock and waits for
    # advisory79 held by the other claimant. Adoption can take jobs first, but
    # must immediately refuse the second relation rather than closing a cycle.
    clone('adoption_mixed_busy','adoption_cf7')
    database='adoption_mixed_busy';slot_name='synthetic-adoption-pm-claim';aerial_name='synthetic-adoption-aerial-claim'
    slot=start_holder(database,slot_name,"begin; select pg_advisory_xact_lock(hashtextextended('property-video-photo-motion-slot-0',79)); select pg_sleep(30); rollback;")
    aerial=None
    try:
        wait_holder(database,slot_name,"l.locktype='advisory' and l.granted",slot)
        aerial=start_holder(database,aerial_name,"begin; select id from public.property_video_aerial_openings where id='83000000-0000-4000-8000-000000000001' for update; select pg_advisory_xact_lock(hashtextextended('property-video-photo-motion-slot-0',79)); rollback;")
        wait_holder(database,aerial_name,"l.locktype='relation' and l.relation='public.property_video_aerial_openings'::regclass and l.mode='RowShareLock' and l.granted",aerial)
        wait_holder(database,aerial_name,"l.locktype='advisory' and not l.granted",aerial)
        unchanged_refusal(database,'could not obtain lock on relation "property_video_aerial_openings"',busy=True)
        # The aerial holder still owns aerial; obtain jobs alone NOWAIT to show
        # the successful first relation lock was rolled back on second failure.
        psql(env,"begin; lock table public.property_video_jobs in access exclusive mode nowait; rollback;",database=database)
    finally:
        if aerial is not None:stop_holder(database,aerial_name,aerial)
        stop_holder(database,slot_name,slot)
    clone('adoption_config_busy','adoption_cf7')
    database='adoption_config_busy';name='synthetic-adoption-config-holder'
    holder=start_holder(database,name,"begin; select key from public.app_config where key='photo_motion_renderer_v2' for update; select pg_sleep(30); rollback;")
    try:
        # Granted RowShare plus active pg_sleep proves SELECT FOR UPDATE
        # completed; row locks normally do not appear as granted tuple locks.
        wait_holder(database,name,"l.locktype='relation' and l.relation='public.app_config'::regclass and l.mode='RowShareLock' and l.granted and a.wait_event='PgSleep'",holder)
        unchanged_refusal(database,'could not obtain lock on row in relation "app_config"',busy=True)
        assert_relations_released(database)
    finally:stop_holder(database,name,holder)
    clone('adoption_rollback','adoption_cf7')
    psql(env,"""create function public.synthetic_adoption_fail()returns trigger language plpgsql as $$begin
      if new.key='photo_motion_renderer_v2_opening' then raise exception 'synthetic mid-adoption failure';end if;return new;end$$;
      create trigger synthetic_adoption_fail before update on public.app_config for each row execute function public.synthetic_adoption_fail();""",database='adoption_rollback')
    unchanged_refusal('adoption_rollback','synthetic mid-adoption failure')
    clone('adoption_success','adoption_cf7')
    before = catalog_snapshot(env,'adoption_success'); rows = data_snapshot(env,'adoption_success')
    apply(env,candidate,database='adoption_success')
    after = catalog_snapshot(env,'adoption_success')
    for signature,expected in zip(CF7_SIGNATURES,expectations):
        old,new = before['functions'][signature],after['functions'][signature]
        if {key:value for key,value in old['catalog'].items() if key!='prosrc'} != {key:value for key,value in new['catalog'].items() if key!='prosrc'} or old['comment']!=new['comment']:
            raise AssertionError('Function OID/authority/settings/comment metadata changed')
        if hashlib.md5(new['catalog']['prosrc'].encode()).hexdigest()!=expected['body_md5']:
            raise AssertionError('Cutover did not append only the expected exact full tuple')
    expected_configs = json.loads(json.dumps(before['configs']))
    for item in configs:
        expected_configs[item['key']]['value']['producer_identity']['controller_sha256']=args.module_sha256
    if after['configs']!=expected_configs or data_snapshot(env,'adoption_success')!=rows:
        raise AssertionError('Cutover changed unrelated config metadata, rows, receipts, quote or cost hold')
    count += assert_identities(env,'adoption_success',expectations,adopted=True)
    # Two actual psql callers start together against the same seeded database.
    # Either may win; only one complete cutover may commit.
    clone('adoption_two_contenders','adoption_cf7')
    barrier=threading.Barrier(2)
    def contend():
        barrier.wait(timeout=5)
        return candidate_result('adoption_two_contenders')
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        contenders=[pool.submit(contend),pool.submit(contend)]
        results=[future.result(timeout=310) for future in contenders]
    if sorted(result.returncode==0 for result in results)!=[False,True]:
        raise AssertionError('Two-controller CAS did not commit exactly once: '+repr([(result.returncode,result.stderr[-1000:]) for result in results]))
    loser=next(result for result in results if result.returncode!=0)
    exact_cas=re.search(r'ERROR:\s+P0001:\s+Controller adoption: function predecessor changed: '+re.escape(CF7_SIGNATURES[0])+r'(?:\r?\n|$)',loser.stderr)
    if not exact_cas and not known_busy_refusal(loser):
        raise AssertionError('Concurrent loser missed exact CAS or intended55P03 fence: '+loser.stderr[-2000:])
    refusal_evidence.append({'database':'adoption_two_contenders','expected':'exact predecessor CAS or known55P03 fence',
                             'known_busy_target':known_busy_refusal(loser),'stderr_tail':loser.stderr[-2000:]})
    if catalog_snapshot(env,'adoption_two_contenders')!=after or data_snapshot(env,'adoption_two_contenders')!=rows:
        raise AssertionError('Concurrent cutover differs from the single exact successful cutover')
    phase_checks.append('two simultaneous same-database callers: one exact cutover, one exact predecessor CAS or known55P03 fence refusal')
    unchanged_refusal('adoption_success','Controller adoption: function predecessor changed: '+CF7_SIGNATURES[0])
    phase_checks.append('exact one cutover; all old history and unrelated data preserved')
    if hashlib.sha256(candidate.read_bytes()).hexdigest()!=args.adoption_sql_sha256:
        raise AssertionError('Candidate SQL changed during fixture')
    if input_hashes != {str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in input_paths}:
        raise AssertionError('Fixture/schema/policy inputs changed during owned adoption proof')
    return {'input_hashes':input_hashes,'suite':'photo_motion_current_controller_adoption','passed':True,'started_at':started_at,
            'module_sha256':args.module_sha256,'adoption_sql':candidate.name,'adoption_sql_sha256':args.adoption_sql_sha256,
            'cf7_seed_sha256':CF7_MIGRATION_SHA256,'function_body_md5':[item['body_md5'] for item in expectations],
            'historical_tuple_counts':[7,5],'identity_assertions':count,'cases':phase_checks,'refusal_evidence':refusal_evidence,
            'synthetic_nonempty_data':{name:row['count'] for name,row in rows.items() if name in
                ['property_video_jobs','property_video_job_sources','property_video_aerial_openings','app_video_cost_reservations']}}


def adoption_arguments():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adoption-sql',type=Path)
    parser.add_argument('--adoption-sql-sha256')
    parser.add_argument('--module-sha256')
    parser.add_argument('--receipt',type=Path)
    args=parser.parse_args()
    selected=[args.adoption_sql,args.adoption_sql_sha256,args.module_sha256,args.receipt]
    if any(selected) and not all(selected):
        parser.error('Current adoption requires exact --adoption-sql, --adoption-sql-sha256, --module-sha256 and --receipt together')
    if all(selected):
        for value in [args.adoption_sql_sha256,args.module_sha256]:
            if not re.fullmatch('[a-f0-9]{64}',value): parser.error('Use exact lowercase SHA256 inputs')
        if args.module_sha256 in {identity['producer_identity']['controller_sha256'] for history in cf7_predecessor()[1] for identity in history}:
            parser.error('New controller must not reuse a historical controller SHA')
        if hashlib.sha256(args.adoption_sql.read_bytes()).hexdigest()!=args.adoption_sql_sha256:
            parser.error('Candidate adoption SQL bytes changed')
        if args.receipt.exists(): parser.error('Do not overwrite an existing fixture receipt')
    return args


def main():
    args = adoption_arguments()
    adoption_receipt = None
    # Explicit Unix socket, no TCP listener, and no inherited connection setting.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("PG") and not key.startswith("SUPABASE") and key != "DATABASE_URL"}
    with tempfile.TemporaryDirectory(prefix="rp-pm-handoff-", dir="/tmp") as owned:
        location = Path(owned)
        data, socket = location / "data", location / "socket"
        socket.mkdir()
        env.update(PGHOST=str(socket), PGPORT="5432", PGUSER="postgres", PGDATABASE="rendprop")
        run(["initdb", "-D", str(data), "-U", "postgres", "-A", "trust", "--encoding=UTF8", "--no-instructions"], env)
        started = False
        try:
            try:
                run(["pg_ctl", "-D", str(data), "-l", str(location / "postgres.log"), "-o",
                     f"-c listen_addresses= -k {socket} -p 5432", "-w", "start"], env)
            except AssertionError as error:
                raise AssertionError(f"{error}\n{(location / 'postgres.log').read_text()[-3000:]}") from error
            started = True
            run(["createdb", "-h", str(socket), "-U", "postgres", "rendprop"], env)
            apply(env, ROOT / "services/supabase/tests/ci-bootstrap.sql")
            paths = sorted(MIGRATIONS.glob("*.sql"), key=lambda path: path.name)
            for path in paths:
                if path.name == AERIAL:
                    psql(env, f"""
do $verify$begin
 if (select md5(prosrc) from pg_proc where oid=to_regprocedure('public.property_video_job_admit_photo_motion(uuid,jsonb)')) is distinct from '{ADMISSION_MD5}'
 or (select md5(prosrc) from pg_proc where oid=to_regprocedure('public.property_video_photo_motion_publication(uuid,uuid,uuid,uuid,jsonb)')) is distinct from '{PUBLICATION_MD5}'
 then raise exception 'Recovered Photo motion predecessor bodies changed';end if;
end$verify$;
""")
                    assert_handoff(env, PREDECESSOR_MD5, renamed=False)
                    # Every recovered predecessor must still fail closed if changed.
                    for index, (signature, replacement) in enumerate((
                        ("public.property_video_photo_motion_saved_identity(text,jsonb)",
                         "create or replace function public.property_video_photo_motion_saved_identity(p_profile text,p_identity jsonb) returns boolean language plpgsql stable security definer set search_path='' as $$begin return true;end$$"),
                        ("public.property_video_job_admit_photo_motion(uuid,jsonb)",
                         "create or replace function public.property_video_job_admit_photo_motion(p_actor uuid,p_manifest jsonb) returns jsonb language plpgsql security definer set search_path='' as $$begin return '{}'::jsonb;end$$"),
                        ("public.property_video_photo_motion_publication(uuid,uuid,uuid,uuid,jsonb)",
                         "create or replace function public.property_video_photo_motion_publication(p_actor uuid,p_listing uuid,p_asset uuid,p_poster uuid,p_manifest jsonb) returns boolean language plpgsql stable security definer set search_path='' as $$begin return true;end$$"),
                    )):
                        database = f"tampered_{index}"
                        run(["createdb", "-h", str(socket), "-U", "postgres", "--template=rendprop", database], env)
                        psql(env, replacement, database=database)
                        rejected = apply(env, path, database=database, ok=False)
                        if f"Aerial composition predecessor changed: {signature}" not in rejected.stderr:
                            raise AssertionError(f"Aerial guard did not identify {signature}: {rejected.stderr[-1500:]}")
                apply(env, path)
                if path.name == PHOTO_PUBLICATION:
                    rejected = apply(env, path, ok=False)
                    if "Review changed photo publication dependency: public.studio_presenter_media_access_inner(uuid)" not in rejected.stderr:
                        raise AssertionError(f"Photo publication second application did not fail closed: {rejected.stderr[-1500:]}")
                if path.name == AERIAL:
                    assert_handoff(env, PREDECESSOR_MD5, renamed=True)
                if path.name == HISTORY:
                    assert_handoff(env, HISTORY_MD5, renamed=True)
                    break
            else:
                raise AssertionError("Photo motion historical handoff migrations were not found")
            # The next controller adoption is intentionally bound to a
            # quarantined historical job. It must refuse this empty database.
            apply(env, MIGRATIONS / "20261023013450_aerial_opening_pro_1080_prospective.sql")
            rejected = apply(env, MIGRATIONS / LIVE_ADOPTION, ok=False)
            if "Producer adoption: quarantined aerial job is not exact terminal pre-generation failure" not in rejected.stderr:
                raise AssertionError(f"Live-state adoption did not fail closed: {rejected.stderr[-1500:]}")
            if args.adoption_sql:
                adoption_receipt = run_current_adoption(env, socket, args)
        finally:
            if started:
                run(["pg_ctl", "-D", str(data), "-m", "immediate", "-w", "stop"], env)
    if adoption_receipt is not None:
        adoption_receipt['owned_cluster_stopped'] = True
        adoption_receipt['historical_phase_passed'] = True
        adoption_receipt['fixture_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        with args.receipt.open('x') as output:
            json.dump(adoption_receipt, output, indent=2); output.write('\n')
        args.receipt.chmod(0o600)
        print('PASS: exact current controller adoption; seeded cf7/history/metadata/CAS/replay/rollback/work fences')
    print("PASS: historical handoffs; changed predecessors, duplicate publication and live-state adoption refused")


if __name__ == "__main__":
    main()
