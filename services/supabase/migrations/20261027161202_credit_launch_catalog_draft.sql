-- Proposed paid-period grants are recorded for review, but cannot mint or
-- advertise monthly credits until the integrated plans, Apple SKUs and retail
-- pricing have been verified together. An activation migration is separate.
begin;

insert into public.credit_monthly_catalog(product_id,credits,active) values
  ('com.rendprop.app.pro29.monthly',80,false),
  ('com.rendprop.app.starter.monthly',200,false),
  ('com.rendprop.app.pro.monthly',440,false),
  ('com.rendprop.app.team.monthly',1000,false)
on conflict(product_id) do nothing;

do $$
begin
  if (select count(*) from public.credit_monthly_catalog
      where (product_id='com.rendprop.app.pro29.monthly' and credits=80 and not active)
         or (product_id='com.rendprop.app.starter.monthly' and credits=200 and not active)
         or (product_id='com.rendprop.app.pro.monthly' and credits=440 and not active)
         or (product_id='com.rendprop.app.team.monthly' and credits=1000 and not active))<>4 then
    raise exception 'RP409: Proposed monthly credit catalog has changed';
  end if;
end$$;

commit;
