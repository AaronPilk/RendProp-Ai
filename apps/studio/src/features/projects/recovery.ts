import {decodeProject,type VideoProject} from "./model";
import {canonicalDocument} from "../../data/documents";

/** Separately keyed recovery snapshots survive opening remote versions. At the
 * bound we stop; silently evicting someone's unconfirmed work is not recovery. */
export function preserveProjectRecovery(storage:Pick<Storage,"getItem"|"setItem">,scope:string,project:VideoProject):VideoProject {
 const saved=decodeProject(project);
 const previous=readProjectRecoveries(storage,scope);
 if(previous.some(p=>canonicalDocument(p)===canonicalDocument(saved)))return saved;
 if(previous.length>=20)throw new Error("This browser has 20 recovery copies. Recover and save a copy, then remove its browser backup before opening another version.");
 storage.setItem(`${scope}:project-recoveries`,JSON.stringify([saved,...previous]));
 return saved;
}
export function readProjectRecovery(storage:Pick<Storage,"getItem">,scope:string):VideoProject|null {
 return readProjectRecoveries(storage,scope)[0]??null;
}
export function readProjectRecoveries(storage:Pick<Storage,"getItem">,scope:string):VideoProject[] {
 try{const raw=storage.getItem(`${scope}:project-recoveries`);if(!raw)return [];const values=JSON.parse(raw);return Array.isArray(values)&&values.length<=20?values.map(decodeProject):[];}catch{return [];}
}
export function removeProjectRecovery(storage:Pick<Storage,"getItem"|"setItem">,scope:string,index:number):VideoProject[] {
 const rows=readProjectRecoveries(storage,scope);if(!Number.isSafeInteger(index)||index<0||index>=rows.length)throw new Error("Choose a browser recovery copy.");
 rows.splice(index,1);storage.setItem(`${scope}:project-recoveries`,JSON.stringify(rows));return rows;
}
