import {checkedPhotoMotionProducer,type PhotoMotionProducer} from './photo-motion';

/** Deployment-specific identifiers are supplied outside the public source. */
export interface PhotoMotionRuntimeConfiguration {
  CPU_PHOTO_MOTION_SLOT_NAME?:string;
  CPU_PHOTO_MOTION_HELD_COMPAT_JOB_ID?:string;
  CPU_PHOTO_MOTION_HELD_COMPAT_IMAGE_URI?:string;
  CPU_PHOTO_MOTION_HELD_COMPAT_CONTROLLER_SHA256?:string;
  CPU_PHOTO_MOTION_HELD_COMPAT_RENDERER_SHA256?:string;
}

export function photoMotionSlotName(value:unknown):string {
  if(typeof value!=='string'||value.length>64||!/^slot-0-[a-z0-9]+(?:-[a-z0-9]+)*$/.test(value))throw Error('photo_motion_slot_unconfigured');
  return value;
}

export function heldPhotoMotionCompatibility(env:PhotoMotionRuntimeConfiguration):{jobID:string;producer:PhotoMotionProducer}|null {
  const values=[env.CPU_PHOTO_MOTION_HELD_COMPAT_JOB_ID,env.CPU_PHOTO_MOTION_HELD_COMPAT_IMAGE_URI,
    env.CPU_PHOTO_MOTION_HELD_COMPAT_CONTROLLER_SHA256,env.CPU_PHOTO_MOTION_HELD_COMPAT_RENDERER_SHA256];
  if(values.every(value=>value===undefined))return null;
  const jobID=env.CPU_PHOTO_MOTION_HELD_COMPAT_JOB_ID;
  if(typeof jobID!=='string'||!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(jobID))throw Error('held_compatibility_unconfigured');
  const producer=checkedPhotoMotionProducer({
    image_uri:env.CPU_PHOTO_MOTION_HELD_COMPAT_IMAGE_URI,
    controller_sha256:env.CPU_PHOTO_MOTION_HELD_COMPAT_CONTROLLER_SHA256,
    renderer_source_sha256:env.CPU_PHOTO_MOTION_HELD_COMPAT_RENDERER_SHA256
  });
  return{jobID,producer};
}
