import { createRoot } from "react-dom/client";
import { useCallback, useState } from "react";
import VideoEditor from "../src/editor/VideoEditor";
import type { EditDraft } from "../src/editor/model";
import type { ConversationState } from "../src/editor/conversation-state";
import type { ConversationOperation } from "../src/editor/conversation";
import "../src/styles.css";

let current: EditDraft | undefined, conversation: ConversationState | undefined, changes = 0;
const requests: { draft: EditDraft; message: string; signal: AbortSignal; resolve: (value: unknown) => void }[] = [];
const enhancementRequests: {draft:EditDraft;message:string;signal:AbortSignal;resolve:(value:unknown)=>void}[]=[];
function Fixture() {
  const [account, setAccount] = useState(0), [assistant, setAssistant] = useState(false), [enhancer,setEnhancer]=useState(false), [active, setActive] = useState(true);
  const [seek, setSeek] = useState<{ id: string; time: number }>();
  const request = useCallback((message: string, draft: EditDraft, _history: ConversationState["messages"], signal: AbortSignal): Promise<unknown> =>
    // Deliberately ignores abort until the test releases it: a stale server response
    // must be fenced by the real component, not rescued by this fixture.
    new Promise(resolve => requests.push({ draft: structuredClone(draft), message, signal, resolve })), []);
  const requestEnhancement=useCallback((message:string,draft:EditDraft,_history:ConversationState["messages"],signal:AbortSignal):Promise<unknown>=>new Promise(resolve=>enhancementRequests.push({draft:structuredClone(draft),message,signal,resolve})),[]);
  Object.assign(window, { conversationFixture: {
    snapshot: () => ({ draft: structuredClone(current), conversation: structuredClone(conversation), changes, account, enhancementRequests:enhancementRequests.map(item=>({draftId:item.draft.id,revision:item.draft.revision,message:item.message,aborted:item.signal.aborted})), requests: requests.map(item => ({ draftId: item.draft.id, revision: item.draft.revision, message: item.message, aborted: item.signal.aborted })) }),
    enableAssistant: () => setAssistant(true),
    enableEnhancer:()=>setEnhancer(true),
    resolveEnhancement:(index:number,value:unknown)=>enhancementRequests[index].resolve(value),
    resolve: (index: number, operations: ConversationOperation[], expectedRevision?: number) => {
      const pending = requests[index];
      pending.resolve({ status: "plan", reply: "Fixture plan", plan: { draftId: pending.draft.id, expectedRevision: expectedRevision ?? pending.draft.revision, operations } });
    },
    resetAccount: () => { current = undefined; conversation = undefined; setAccount(value => value + 1); setActive(true); },
    active: (value: boolean) => setActive(value),
    seek: (time: number) => setSeek({ id: crypto.randomUUID(), time }),
  } });
  return <main style={{ padding: 20, maxWidth: 1440, margin: "auto" }}><VideoEditor key={account} initialMode="conversation" active={active}
    seekRequest={seek} editAssistAvailable={assistant} requestEditPlan={request} promptEnhanceAvailable={enhancer} requestPromptEnhancement={requestEnhancement}
    onDraftChange={(draft, chat) => { current = structuredClone(draft); conversation = structuredClone(chat); changes++; }} /></main>;
}
createRoot(document.getElementById("root")!).render(<Fixture />);
