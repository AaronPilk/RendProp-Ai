-- 0002_multipart.sql — resumable multipart upload state on capture_assets.
--
-- A 9-minute 4K walkthrough is 2–8 GB and a listing can carry 70+ photos. A single
-- presigned PUT cannot resume after a dropped connection and R2 caps single PUTs at
-- 5 GB, so large video uploads use S3/R2 MULTIPART (Create → UploadPart ×N → Complete).
-- We persist the multipart session on the asset row (not just on the device) so the
-- upload can resume from another launch/device and so the server can presign part
-- URLs and complete/abort the upload from the asset id alone.
--
-- Applied to project ymgqpbnjpztwjsyvceld (public schema).

alter table capture_assets
  add column if not exists upload_id     text,      -- R2/S3 multipart UploadId (null = single PUT)
  add column if not exists part_size     bigint,    -- uniform part size in bytes (last part may be smaller)
  add column if not exists parts_total   integer,   -- expected number of parts
  add column if not exists content_type  text;      -- MIME type the object was created with

comment on column capture_assets.upload_id is
  'R2/S3 multipart UploadId. Non-null while a resumable multipart upload is in flight or completing.';
