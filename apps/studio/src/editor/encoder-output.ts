import type {StreamTargetChunk} from "mediabunny";

export const PAGE_BYTES=64*1024, MAX_PAGES=2048, MAX_EXTENT=PAGE_BYTES*MAX_PAGES;
export type OutputPage={index: number; bytes: ArrayBuffer};
export type PagedOutput={extent: number; pages: OutputPage[]};

/** Seekable MP4 storage: bound the final extent before allocating any page. */
export function createPagedWritableTarget() {
  const pages=new Map<number,Uint8Array<ArrayBuffer>>();
  let extent=0, state: "open"|"closed"|"aborted"|"claimed"="open";
  let controller: WritableStreamDefaultController | undefined;
  const requireOpen=()=>{if(state!=="open")throw new Error(`Paged output is ${state}.`);};
  const clear=()=>{for(const page of pages.values())page.fill(0);pages.clear();extent=0;};
  const writable=new WritableStream<StreamTargetChunk>({
    start(value){controller=value;},
    write(chunk){
      requireOpen();
      if(!chunk || chunk.type!=="write" || !Number.isSafeInteger(chunk.position) || chunk.position<0 ||
          !(chunk.data instanceof Uint8Array))throw new TypeError("Invalid seekable output write.");
      const {position,data}=chunk;
      if(position>MAX_EXTENT || data.byteLength>MAX_EXTENT-position)
        throw new RangeError("The exported video exceeds 128 MiB.");
      if(!data.byteLength)return;
      let consumed=0;
      while(consumed<data.byteLength){
        const absolute=position+consumed,index=Math.floor(absolute/PAGE_BYTES),offset=absolute%PAGE_BYTES;
        const count=Math.min(data.byteLength-consumed,PAGE_BYTES-offset);
        let page=pages.get(index);
        if(!page){
          if(pages.size>=MAX_PAGES)throw new RangeError("The output page limit was exceeded.");
          page=new Uint8Array(PAGE_BYTES);pages.set(index,page);
        }
        page.set(data.subarray(consumed,consumed+count),offset);consumed+=count;
      }
      extent=Math.max(extent,position+data.byteLength);
    },
    close(){requireOpen();state="closed";},
    abort(){if(state==="claimed")return;state="aborted";clear();},
  },{highWaterMark:1});
  return {
    writable,
    stats:()=>Object.freeze({state,extent,allocatedPages:pages.size,allocatedBytes:pages.size*PAGE_BYTES}),
    claimSuccessfulOutput(): PagedOutput {
      if(state!=="closed")throw new Error("Only a successfully closed output can be claimed.");
      const result={extent,pages:[...pages.entries()].sort(([a],[b])=>a-b)
        .map(([index,bytes])=>({index,bytes:bytes.buffer}))};
      pages.clear();extent=0;state="claimed";return result;
    },
    dispose(){
      if(state==="claimed" || state==="aborted")return;
      state="aborted";clear();
      try{controller?.error(new Error("Output storage was disposed."));}catch{/* Already closed. */}
    },
  };
}

export function outputBlob(row: PagedOutput): Blob {
  if(!Number.isSafeInteger(row.extent) || row.extent<1 || row.extent>MAX_EXTENT ||
      !Array.isArray(row.pages) || row.pages.length<1 || row.pages.length>MAX_PAGES)
    throw new Error("Invalid final paged output.");
  const pages=new Map<number,ArrayBuffer>(),owned=new Set<ArrayBuffer>();let previous=-1;
  for(const page of row.pages){
    if(!Number.isSafeInteger(page.index) || page.index<=previous || page.index>=MAX_PAGES ||
        page.index*PAGE_BYTES>=row.extent || !(page.bytes instanceof ArrayBuffer) || page.bytes.byteLength!==PAGE_BYTES ||
        owned.has(page.bytes))
      throw new Error("Invalid transferred output page inventory.");
    pages.set(page.index,page.bytes);owned.add(page.bytes);previous=page.index;
  }
  if(previous!==Math.floor((row.extent-1)/PAGE_BYTES))throw new Error("The final output page is missing.");
  const parts: BlobPart[]=[],zero=new ArrayBuffer(PAGE_BYTES);
  for(let at=0,index=0;at<row.extent;at+=PAGE_BYTES,index++)
    parts.push(new Uint8Array(pages.get(index)??zero,0,Math.min(PAGE_BYTES,row.extent-at)));
  // Sparse file positions are zero; this never pads missing audio/video samples.
  return new Blob(parts,{type:"video/mp4"});
}
