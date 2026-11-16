import { useEffect, useState } from "react";
import { StudioError } from "../../data/config";
import type { Workspace } from "../../data/contracts";
import type { StudioServices } from "../../data/services";
import { photoFeedbackReport, REPORT_WINDOWS, type Fact, type ReportView, type ReportWindow, type Row } from "./photo-feedback-report";

// Shared panel, grid and segmented-control styles; this page ships no stylesheet.
const muted = (value: string) => <p className="muted">{value}</p>;
const facts = (items: Fact[]) => <div className="settings-grid">{items.map(([label, value, detail]) =>
  <section key={label} className="panel">{muted(label)}<h3>{value}</h3>{detail && muted(detail)}</section>)}</div>;
const table = (head: string[], rows: Row[]) => rows.length ? <div style={{ overflowX: "auto" }}><table style={{ borderSpacing: "16px 8px", whiteSpace: "nowrap", textAlign: "left" }}>
  <thead><tr>{head.map(name => <th key={name} scope="col">{name}</th>)}</tr></thead>
  <tbody>{rows.map(row => <tr key={row[0]}>{row.map((cell, index) => index ? <td key={index}>{cell}</td> : <th key={index} scope="row">{cell}</th>)}</tr>)}</tbody>
</table></div> : muted("None in this window.");

/** Internal quality report. The server is the gate: nothing from the report is
 * shown unless GET /admin/photo-feedback answers 200 for this account. It reads
 * aggregates only and never opens customer images. */
export default function PhotoFeedbackReport({ services, workspace }: { services: StudioServices; workspace: Workspace }) {
  const [range, setRange] = useState<ReportWindow>("30d"), [load, setLoad] = useState<ReportView | string | null>(null);
  useEffect(() => {
    const controller = new AbortController();
    setLoad(null);
    void (async () => {
      try {
        const view = photoFeedbackReport(await services.api(`/functions/v1/admin/photo-feedback?window=${range}`, { orgId: workspace.org.id, signal: controller.signal }));
        if (!controller.signal.aborted) setLoad(view);
      } catch (error) {
        if (!controller.signal.aborted) setLoad(error instanceof StudioError && (error.status === 401 || error.status === 403)
          ? "This report is only available to Rendprop administrators." : error instanceof Error ? error.message : "The report could not be loaded.");
      }
    })();
    return () => controller.abort();
  }, [services, workspace.org.id, range]);
  const view = typeof load === "object" ? load : null;
  return <section aria-label="Photo feedback report">
    <p className="eyebrow">Internal · admin only</p>
    <h1>Photo feedback report</h1>
    <div className="video-photo-actions" role="group" aria-label="Report window">
      {REPORT_WINDOWS.map(value => <button key={value} type="button" aria-pressed={range === value} onClick={() => setRange(value)}>{value.replace("d", " days")}</button>)}
    </div>
    {load === null ? <p role="status">Checking report access…</p> : typeof load === "string" && <p role="alert">{load}</p>}
    {view && <>
      {muted(view.range)}
      <section className="panel" role="note">{view.honesty.map(line => <p key={line}>{line}</p>)}</section>
      <h2>Explicit feedback</h2>{facts(view.explicit)}
      <h2>Defect reasons</h2>{muted(`${view.groups}. One verdict can name several reasons.`)}
      {table(["Reason", "Group", "Verdicts", "Outputs"], view.reasons)}
      {view.breakdowns.map(([title, rows]) => <div key={title}><h2>{title}</h2>{table(["Setting", "Generated", "Reviewed", "Useful rate"], rows)}</div>)}
      <h2>Cost</h2>{facts(view.cost)}{muted(view.costBasis)}
      <h2>Outcome signals</h2>{facts(view.signals)}{muted(view.signalsNote)}
      {muted(view.regression)}{muted(view.sampleNote)}
    </>}
  </section>;
}
