import subprocess,time,uuid,json

def concurrent_checks(psql,env,out,run):
 a,b,o,doc=[str(uuid.uuid4()) for _ in range(4)]
 setup=f"""insert into auth.users(id,email) values('{a}','race-a@fixture.invalid'),('{b}','race-b@fixture.invalid');
 insert into memberships(user_id,org_id,role) select '{b}',org_id,'agent' from memberships where user_id='{a}';
 select org_id from memberships where user_id='{a}';"""
 run('race-setup',psql+['-Atc',setup]);o=run('race-org',psql+['-Atc',f"select org_id from memberships where user_id='{a}';"]).strip()
 for i in range(1,4):
  run(f'race-reserve-{i}',psql+['-Atc',f"set role service_role;select studio_project_media_write('{a}','{o}','{uuid.uuid4()}','reserve','{json.dumps({'sha256':str(i)*64,'bytes':134217728,'mime':'video/mp4','filename':'race.mp4','modified':0})}');"])
 def race(label,left,right):
  path=out/(label+'-first.log')
  with path.open('w') as f:
   first=subprocess.Popen(psql+['-Atc',"set application_name='private-media-independent-race';begin;set role service_role;"+left+";select pg_sleep(0.8);commit;"],env=env,text=True,stdout=f,stderr=subprocess.STDOUT)
   deadline=time.monotonic()+5
   try:
    while time.monotonic()<deadline:
     status=subprocess.run(psql+['-Atc',"select count(*) from pg_stat_activity where application_name='private-media-independent-race' and wait_event='PgSleep';"],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=3)
     if status.stdout.strip()=='1':break
     if first.poll() is not None:raise RuntimeError(path.read_text())
     time.sleep(.025)
    else:raise RuntimeError('race barrier unavailable')
    second=subprocess.run(psql+['-Atc','set role service_role;'+right+';'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=10)
    (out/(label+'-second.log')).write_text(second.stdout)
    assert first.wait(timeout=5)==0,path.read_text()
    assert second.returncode!=0 and 'RP' in second.stdout,second.stdout
   finally:
    if first.poll() is None:first.terminate();first.wait(timeout=5)
  return second.stdout
 def reserve(who,sha):
  return f"select studio_project_media_write('{who}','{o}','{uuid.uuid4()}','reserve','{json.dumps({'sha256':sha*64,'bytes':134217728,'mime':'video/mp4','filename':'quota-race.mp4','modified':0})}')"
 assert '512 MiB' in race('quota-race',reserve(a,'a'),reserve(b,'b'))
 assert run('quota-race-final',psql+['-Atc',f"select sum(bytes) from studio_project_media where org_id='{o}';"]).strip()=='536870912'
 payload=json.dumps({'schema':1,'name':'first','archived':False,'listingId':None,'draft':{},'sources':[]})
 payload2=payload.replace('first','second')
 def save(p):return f"select studio_save_project('{a}','{o}','project:{doc}',null,0,'{p}'::jsonb)"
 assert 'RP409' in race('project-cas-race',save(payload),save(payload2))
 assert run('project-cas-final',psql+['-Atc',f"select revision||':'||(payload->>'name') from studio_documents where user_id='{a}' and org_id='{o}' and key='project:{doc}';"]).strip()=='1:first'
 return {'quota_race':'one write admitted, one refused; exact 512 MiB','project_cas_race':'one revision-1 insert, one 409; first payload preserved'}
