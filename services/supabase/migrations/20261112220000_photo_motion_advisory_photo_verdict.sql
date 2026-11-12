-- Photo Motion and property-video photo sources: the advisory photo verdict no
-- longer decides whether an edited photo the user selected may be used.
--
-- OWNER DECISION, 12 Nov 2026: no quality-check outcome may block an AI photo;
-- the agent is responsible for what they post. Both functions below refused a
-- photo whose disclosure record carried a judge verdict other than 'pass',
-- even though that edit was delivered and accepted. One clause is removed from
-- each. Everything else they require of a photo stays: the disclosure record
-- must be publishable with action accept/pass, and its output_sha256 must be
-- the exact bytes of the selected asset.
--
-- Independent of the photo-quality migration (20261112193000) and of the
-- video lane's 20261112213000 / 20261112214000, which rewrite other
-- functions. Safe to apply once: both functions are pinned to their
-- predecessor md5 and the migration aborts untouched if either changed.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $rewrite$
declare c record;d text;before_meta jsonb;
begin
 for c in select * from (values
   ('public.property_video_photo_motion_publication(uuid,uuid,uuid,uuid,jsonb)','795d0bde8b7af325f0fc43aafcb27567',$n$and(not(p.qc?'verdict')or p.qc->>'verdict'='pass')$n$),
   ('public.property_video_photo_motion_manifest_before_opening_20261022(uuid,jsonb)','2059470d9f9f5332cfb9db0b2df67ddd',$n$or(proof.qc?'verdict'and proof.qc->>'verdict'is distinct from'pass')$n$)
  ) as v(signature,expected,needle)
 loop
  if (select md5(prosrc) from pg_proc where oid = c.signature::regprocedure) is distinct from c.expected then
   raise exception '% changed since 2026-11-12; review the advisory photo verdict rewrite before applying', c.signature;
  end if;
 end loop;
 for c in select * from (values
   ('public.property_video_photo_motion_publication(uuid,uuid,uuid,uuid,jsonb)',$n$and(not(p.qc?'verdict')or p.qc->>'verdict'='pass')$n$),
   ('public.property_video_photo_motion_manifest_before_opening_20261022(uuid,jsonb)',$n$or(proof.qc?'verdict'and proof.qc->>'verdict'is distinct from'pass')$n$)
  ) as v(signature,needle)
 loop
  select to_jsonb(p)-'prosrc'-'prosqlbody',pg_get_functiondef(p.oid)into before_meta,d from pg_proc p where p.oid=c.signature::regprocedure;
  if length(d)-length(replace(d,c.needle,''))<>length(c.needle)then raise exception '% photo verdict clause not found exactly once',c.signature;end if;
  execute replace(d,c.needle,'');
  if(select to_jsonb(p)-'prosrc'-'prosqlbody'from pg_proc p where p.oid=c.signature::regprocedure)is distinct from before_meta then raise exception '% metadata changed',c.signature;end if;
  if(select prosrc from pg_proc where oid=c.signature::regprocedure)like'%verdict%'then raise exception '% still reads a photo verdict',c.signature;end if;
  if(select prosrc from pg_proc where oid=c.signature::regprocedure)not like'%output_sha256%'or(select prosrc from pg_proc where oid=c.signature::regprocedure)not like'%publishable%'then raise exception '% lost its exact-bytes or publishable requirement',c.signature;end if;
 end loop;
end
$rewrite$;
commit;
