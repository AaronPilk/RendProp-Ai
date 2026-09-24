import {useEffect,useRef,useId} from "react";
import type {ConversationState} from "./conversation-state";
import type {PromptEnhancement} from "./prompt-enhancement";
export type {ConversationState} from "./conversation-state";
import "./conversation.css";

type Props={conversation:ConversationState;prompt:string;busy:boolean;cancellable:boolean;blockedReason?:string;hasMedia:boolean;assistAvailable:boolean;onPrompt:(text:string)=>void;onSubmit:()=>void;onAdd:()=>void;onLibrary?:()=>void;onCancel:()=>void;waitingForMedia:boolean;enhancement:PromptEnhancement|null;enhancing:boolean;onEnhance:()=>void;onUseEnhancement:()=>void;onDismissEnhancement:()=>void};
export default function ConversationPanel(props:Props){
  const log=useRef<HTMLDivElement>(null),inputId=useId();
  useEffect(()=>{if(log.current)log.current.scrollTop=log.current.scrollHeight;},[props.conversation.messages.length,props.busy]);
  const suggestions=props.hasMedia?["Make it shorter","Add slow zooms","Use smooth transitions"]:["Make a 15-second reel","Create a listing highlight","Make a vertical video"];
  return <section className="creation-chat" aria-label="Create with chat">
    <header><span className="creation-kicker">YOUR CREATIVE WORKSPACE</span><h3>{props.hasMedia?"What should we change?":"What would you like to make?"}</h3><p>{props.hasMedia?"Ask for a change. Preview it here. Every edit has Undo.":"Add your photos or clips, then tell us what you have in mind."}</p></header>
    <div className="creation-chat-log" ref={log} role="log" aria-label="Editing conversation" aria-live="polite" aria-relevant="additions text">
      {!props.conversation.messages.length&&<div className="creation-chat-welcome"><span aria-hidden="true">✦</span><p>“Make a 15-second reel. Use slow zooms and smooth transitions.”</p><small>Start with your footage. Keep creating from the same draft.</small></div>}
      {props.conversation.messages.map(item=><article key={item.id} className={`creation-message creation-message-${item.role}`}><span>{item.role==="user"?"You":"Rendprop"}</span><p>{item.text}</p></article>)}
      {props.busy&&<p className="creation-thinking" role="status">{props.enhancing?"Improving your prompt…":"Working on your edit…"}</p>}
    </div>
    <form className="creation-composer" onSubmit={event=>{event.preventDefault();props.onSubmit();}}>
      <label className="sr-only" htmlFor={inputId}>Describe your video or edit</label>
      <textarea id={inputId} aria-label="Describe your video or edit" rows={3} maxLength={2000} placeholder={props.hasMedia?"Make it shorter, put clip 3 first, add a title…":"Make a 15-second reel from these photos…"} value={props.prompt} disabled={props.busy} onChange={event=>props.onPrompt(event.target.value)} onKeyDown={event=>{if(event.key==="Enter"&&!event.shiftKey&&!event.nativeEvent.isComposing){event.preventDefault();props.onSubmit();}}}/>
      <button className="creation-enhance-button" type="button" disabled={props.busy||!props.prompt.trim()} onClick={props.onEnhance}>✦ Improve prompt</button>
      <div className="creation-composer-actions"><button type="button" disabled={props.busy} onClick={props.onAdd}>＋ Add media</button>{props.onLibrary&&<button type="button" disabled={props.busy} onClick={props.onLibrary}>From my phone</button>}{props.busy&&props.cancellable?<button type="button" onClick={props.onCancel}>Stop</button>:<button className="rp-editor-primary" type="submit" disabled={props.busy||!props.prompt.trim()}>{props.hasMedia?"Update video":"Start creating"}<span aria-hidden="true"> ↑</span></button>}</div>
    </form>
    {props.enhancement&&<section className="creation-enhancement" aria-label="Prompt suggestion">
      <header><strong>{props.enhancement.method==="ai"?"AI prompt suggestion":"Guided prompt suggestion"}</strong><p>Review this before using it. Your video has not changed.</p></header>
      <details><summary>Your original</summary><p>{props.enhancement.original}</p></details>
      <p className="creation-enhanced-text">{props.enhancement.enhanced}</p>
      {props.enhancement.notes.length>0&&<ul>{props.enhancement.notes.map((note,index)=><li key={index}>{note}</li>)}</ul>}
      <div><button className="rp-editor-primary" type="button" disabled={props.busy} onClick={props.onUseEnhancement}>Use this prompt</button><button type="button" disabled={props.busy} onClick={props.onDismissEnhancement}>Keep original</button></div>
    </section>}
    <div className="creation-suggestions" aria-label="Editing ideas">{suggestions.map(text=><button key={text} type="button" disabled={props.busy} onClick={()=>props.onPrompt(text)}>{text}</button>)}</div>
    {props.waitingForMedia&&<p className="creation-help" role="status">Add media to continue your request. <button type="button" onClick={props.onCancel}>Clear request</button></p>}
    {props.blockedReason&&<p className="creation-help" role="status">{props.blockedReason}</p>}
    <details className="creation-help"><summary>What can I ask for?</summary><p>Length, clip order, titles, captions, photo movement, transitions, shape and original sound. Refer to clips by their number. We cannot identify rooms or speech from the pictures here.</p><p>{props.assistAvailable?"Freeform requests use the configured text assistant. Only your brief and editing settings are sent; source media stays out of that request.":"Quick editing commands work here without a model call. Freeform AI planning is not enabled in this workspace."} Generated scenes, music and digital presenters are separate capabilities.</p></details>
  </section>;
}
