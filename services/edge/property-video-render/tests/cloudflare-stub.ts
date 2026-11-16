/** Isolated controller dependency double, not a substitute for hosted acceptance. */
export class DurableObject {
  ctx:any;env:any;
  constructor(ctx:any,env:any){this.ctx=ctx;this.env=env;}
}
export class WorkerEntrypoint extends DurableObject {}
