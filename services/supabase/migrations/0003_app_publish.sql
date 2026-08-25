-- 0003_app_publish.sql — let the app publish its OWN on-device render as the tour.
--
-- The on-device RenderEngine already produces the all-intra "scrub master" mp4 —
-- that IS the tour video. So the base hosted tour does NOT need the Python render
-- worker: the app uploads its rendered mp4 straight to the public renders bucket
-- and publishes it. To route an upload to the renders bucket (vs the private
-- uploads bucket) we tag the capture_assets row with which bucket it lives in.
--
-- Applied to project ymgqpbnjpztwjsyvceld (public schema).

alter table capture_assets
  add column if not exists bucket text not null default 'uploads'
    check (bucket in ('uploads', 'renders'));

comment on column capture_assets.bucket is
  'Which R2 bucket the object lives in: uploads (private raw capture) or renders (public, app-rendered tour mp4).';
