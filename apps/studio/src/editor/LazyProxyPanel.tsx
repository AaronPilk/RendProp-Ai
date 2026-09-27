import {lazy,Suspense,useState} from "react";
import type {ProxyPanelProps} from "./ProxyPanel";
const ProxyPanel=lazy(()=>import("./ProxyPanel"));
/** The encoder and incremental hash implementation load only on request. */
export default function LazyProxyPanel(props:ProxyPanelProps){
 const [opened,setOpened]=useState(false),[visible,setVisible]=useState(false);
 return <details className="rp-editor-proxy" onToggle={event=>{const open=event.currentTarget.open;setVisible(open);if(open)setOpened(true);}}><summary>Large video? Create an editing copy</summary>
  {opened&&<Suspense fallback={<p role="status">Opening video preparation…</p>}><ProxyPanel {...props} active={props.active&&visible}/></Suspense>}
 </details>;
}
