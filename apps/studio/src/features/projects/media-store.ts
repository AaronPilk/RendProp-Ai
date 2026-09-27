/** Account/workspace-scoped browser originals. Blob writes complete before the
 * UI calls media backed up. Browser eviction is possible; this is not cloud sync. */
const DB="rendprop-media-v1",STORE="sources",MAX_BYTES=512*1024*1024;
type Stored={key:string;scope:string;hash:string;file:Blob;name:string;lastModified:number;updatedAt:number};
function request<T>(value:IDBRequest<T>):Promise<T>{return new Promise((resolve,reject)=>{value.onsuccess=()=>resolve(value.result);value.onerror=()=>reject(value.error??new Error("Browser media storage is unavailable."));});}
async function database():Promise<IDBDatabase>{if(typeof indexedDB==="undefined")throw new Error("This browser cannot keep original files between visits.");const open=indexedDB.open(DB,1);open.onupgradeneeded=()=>{const store=open.result.createObjectStore(STORE,{keyPath:"key"});store.createIndex("scope","scope");};return request(open);}
function complete(tx:IDBTransaction):Promise<void>{return new Promise((resolve,reject)=>{tx.oncomplete=()=>resolve();tx.onabort=tx.onerror=()=>reject(tx.error??new Error("Browser media storage is full or unavailable."));});}
function key(scope:string,hash:string):string{if(!scope||scope.length>300||!/^[a-f0-9]{64}$/.test(hash))throw new Error("Invalid media backup identity.");return `${scope}:${hash}`;}
export async function storeProjectFile(scope:string,hash:string,file:File,signal?:AbortSignal):Promise<void>{
 signal?.throwIfAborted();const id=key(scope,hash);if(file.size<1||file.size>128*1024*1024)throw new Error("This file exceeds browser backup limits.");
 const db=await database();
 try{signal?.throwIfAborted();const tx=db.transaction(STORE,"readwrite"),done=complete(tx),store=tx.objectStore(STORE);void done.catch(()=>{});const cancel=()=>{try{tx.abort();}catch{/* A committed transaction cannot be aborted. */}};signal?.addEventListener("abort",cancel,{once:true});
  try{const entries=await request(store.index("scope").getAll(scope)) as Stored[];if(entries.filter(e=>e.key!==id).reduce((sum,e)=>sum+e.file.size,0)+file.size>MAX_BYTES){tx.abort();await done.catch(()=>{});throw new Error("Browser media backup has reached 512 MiB. Keep the originals or save them to a property.");}
   signal?.throwIfAborted();store.put({key:id,scope,hash,file,name:file.name,lastModified:file.lastModified,updatedAt:Date.now()} satisfies Stored);await done;signal?.throwIfAborted();
  }finally{signal?.removeEventListener("abort",cancel);}
 }finally{db.close();}
}
export async function readProjectFile(scope:string,hash:string,signal?:AbortSignal):Promise<File|null>{
 signal?.throwIfAborted();const db=await database();try{const row=await request(db.transaction(STORE,"readonly").objectStore(STORE).get(key(scope,hash))) as Stored|undefined;signal?.throwIfAborted();return row?new File([row.file],row.name,{type:row.file.type,lastModified:row.lastModified}):null;}finally{db.close();}
}
export async function clearProjectFiles(scope:string):Promise<void>{const db=await database();try{const tx=db.transaction(STORE,"readwrite"),done=complete(tx),store=tx.objectStore(STORE);for(const row of await request(store.index("scope").getAllKeys(scope)))store.delete(row);await done;}finally{db.close();}}
