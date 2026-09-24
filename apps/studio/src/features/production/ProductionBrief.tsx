import {FORMATS,type ProductionPlan} from "./model";

export default function ProductionBrief({plan}:{plan:ProductionPlan}){
  return <details className="production-panel"><summary>Capture brief shared with this version</summary>
    <p><strong>{FORMATS.find(format=>format.id===plan.recipe)?.title}</strong> · {plan.targetSeconds} second target · {plan.presentation==="on-camera"?"Speak on camera":plan.presentation==="voiceover"?"Voiceover":"Property visuals"}</p>
    {plan.notes&&<p style={{whiteSpace:"pre-wrap",overflowWrap:"anywhere"}}>{plan.notes}</p>}
    <ul>{plan.shots.filter(shot=>shot.notes||shot.sourcePhotoIds.length||shot.sourceVideoIds.length).map(shot=><li key={shot.id}><strong>{shot.title}</strong>{shot.notes&&<> — {shot.notes}</>}<small> · {shot.sourcePhotoIds.length} linked photos, {shot.sourceVideoIds.length} linked videos</small></li>)}</ul>
    <p className="muted">This is the saved brief from submission. Later private notes do not change it.</p>
  </details>;
}
