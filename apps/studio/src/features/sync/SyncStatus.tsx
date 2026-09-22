import type { SyncState } from "../../data/documents";
export default function SyncStatus({state,retry,reload}:{state:SyncState;retry:()=>void;reload:()=>void}) {
 return <div className={`sync-status sync-${state}`} role="status">
  <span>{state==="loading"?"Opening saved work…":state==="saving"?"Saving to your account…":state==="saved"?"Saved to your account":state==="conflict"?"A newer version was saved on another device. Your browser copy is preserved.":"Cloud save paused. Your browser copy is preserved."}</span>
  {state==="offline"&&<button onClick={retry}>Retry sync</button>}
  {state==="conflict"&&<button onClick={reload}>Reload saved version</button>}
 </div>;
}
