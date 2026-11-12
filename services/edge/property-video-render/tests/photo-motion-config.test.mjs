import assert from 'node:assert/strict';
import {build} from 'esbuild';
import {mkdtemp,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {createRequire} from 'node:module';

const directory=await mkdtemp(path.join(tmpdir(),'rendprop-photo-config-'));
try {
  const target=path.join(directory,'config.cjs');
  await build({entryPoints:['src/photo-motion-config.ts'],bundle:true,platform:'node',format:'cjs',outfile:target});
  const {photoMotionSlotName,heldPhotoMotionCompatibility}=createRequire(import.meta.url)(target);
  const config=JSON.parse(await readFile('wrangler.jsonc','utf8'));
  const photoImage=config.containers.find(item=>item.class_name==='PhotoMotionCPU').images.cpu.image;
  const aiImage=config.containers.find(item=>item.class_name==='PropertyVideoCPU').images.cpu.image;
  assert.equal(config.vars.ENABLED,'false');
  assert.equal(config.keep_vars,true);
  assert.equal(config.vars.CPU_PHOTO_MOTION_IMAGE_URI,photoImage);
  assert.equal(config.vars.CPU_TEMPORAL_PRODUCER_IMAGE_URI,aiImage);
  assert.equal(config.vars.CPU_PHOTO_MOTION_RENDERER_SHA256,'9c4e21b2daa4b70a4725138a8ca21465e3eab433f094bd4f557e4f68b5ee83b9');
  assert.equal(config.vars.CPU_PHOTO_MOTION_CONTROLLER_SHA256,undefined);
  assert.equal(config.vars.CPU_PHOTO_MOTION_SLOT_NAME,undefined);
  for(const name of ['CPU_PHOTO_MOTION_HELD_COMPAT_JOB_ID','CPU_PHOTO_MOTION_HELD_COMPAT_IMAGE_URI',
    'CPU_PHOTO_MOTION_HELD_COMPAT_CONTROLLER_SHA256','CPU_PHOTO_MOTION_HELD_COMPAT_RENDERER_SHA256'])
    assert.equal(config.vars[name],undefined);
  assert.equal(config.durable_objects.bindings.find(item=>item.name==='PHOTO_MOTION_CPU').class_name,'PhotoMotionCPU');

  assert.equal(photoMotionSlotName('slot-0-fixture'),'slot-0-fixture');
  for(const bad of [undefined,'','slot-0','slot-1-fixture','../slot-0-fixture','slot-0-UPPER','slot-0-'+'a'.repeat(60)])
    assert.throws(()=>photoMotionSlotName(bad),/photo_motion_slot_unconfigured/);

  assert.equal(heldPhotoMotionCompatibility({}),null);
  const held={
    CPU_PHOTO_MOTION_HELD_COMPAT_JOB_ID:'00000000-0000-4000-8000-000000000001',
    CPU_PHOTO_MOTION_HELD_COMPAT_IMAGE_URI:photoImage,
    CPU_PHOTO_MOTION_HELD_COMPAT_CONTROLLER_SHA256:'b'.repeat(64),
    CPU_PHOTO_MOTION_HELD_COMPAT_RENDERER_SHA256:'c'.repeat(64)
  };
  assert.deepEqual(heldPhotoMotionCompatibility(held),{
    jobID:held.CPU_PHOTO_MOTION_HELD_COMPAT_JOB_ID,
    producer:{image_uri:photoImage,controller_sha256:'b'.repeat(64),renderer_source_sha256:'c'.repeat(64)}
  });
  assert.throws(()=>heldPhotoMotionCompatibility({...held,CPU_PHOTO_MOTION_HELD_COMPAT_JOB_ID:undefined}),/held_compatibility_unconfigured/);
  assert.throws(()=>heldPhotoMotionCompatibility({...held,CPU_PHOTO_MOTION_HELD_COMPAT_IMAGE_URI:aiImage}),/photo_motion_image_refused/);
  assert.throws(()=>heldPhotoMotionCompatibility({...held,CPU_PHOTO_MOTION_HELD_COMPAT_CONTROLLER_SHA256:undefined}),/photo_motion_producer_refused/);
  console.log('Photo Motion controller configuration: pinned dual images and closed private identifiers passed.');
} finally {await rm(directory,{recursive:true,force:true});}
