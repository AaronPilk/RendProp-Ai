export type ConversationMessage = {id:string;role:"user"|"assistant";text:string;revision:number|null};
export type ConversationState = {schema:1;draftId:string;messages:ConversationMessage[]};
export const CONVERSATION_LIMIT = 24;
export function emptyConversation(draftId:string):ConversationState{return {schema:1,draftId,messages:[]};}
export function decodeConversation(value:unknown,draftId:string):ConversationState {
  if(value===undefined||value===null)return emptyConversation(draftId);
  if(!value||typeof value!=="object"||Array.isArray(value))throw new Error("Saved conversation could not be read.");
  const row=value as ConversationState;
  if(row.schema!==1||row.draftId!==draftId||!Array.isArray(row.messages)||row.messages.length>CONVERSATION_LIMIT)throw new Error("The conversation belongs to a different edit or version.");
  const ids=new Set<string>();
  const messages=row.messages.map(item=>{
    if(!item||typeof item!=="object"||typeof item.id!=="string"||!/^[a-f0-9-]{36}$/i.test(item.id)||ids.has(item.id)||!["user","assistant"].includes(item.role)||typeof item.text!=="string"||!item.text.trim()||item.text.length>2000||/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(item.text)||!(item.revision===null||Number.isSafeInteger(item.revision)&&item.revision>=0))throw new Error("A saved conversation message is invalid.");
    ids.add(item.id);return {id:item.id,role:item.role,text:item.text,revision:item.revision};
  });
  return {schema:1,draftId,messages};
}
export function appendConversation(state:ConversationState,role:ConversationMessage["role"],text:string,revision:number|null):ConversationState {
  return decodeConversation({...state,messages:[...state.messages,{id:crypto.randomUUID(),role,text:text.slice(0,2000),revision}].slice(-CONVERSATION_LIMIT)},state.draftId);
}
