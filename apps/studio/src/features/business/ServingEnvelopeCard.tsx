import { envelopeMoney, envelopeResetLine, envelopeTitle, type ServingEnvelope } from "../../data/serving-envelope";
const displayDate = (value: string) => new Intl.DateTimeFormat(undefined, { dateStyle: "medium" }).format(new Date(value));
/** The money gate behind the meters: what the server has counted, what it is
 * holding for work still running, and what is left to admit. */
export function ServingEnvelopeCard({ value }: { value: ServingEnvelope }) {
  const used = Math.min(value.spentCents + value.heldCents, value.ceilingCents);
  const reset = envelopeResetLine(value, displayDate);
  const poolLeft = value.pool ? Math.max(0, value.pool.capCents - value.pool.spentCents) : null;
  return <section className="business-card" aria-label={envelopeTitle(value)}><h3>{envelopeTitle(value)}</h3>
    <div className="business-meter-grid"><div className="business-meter"><div><strong>{envelopeMoney(value.availableCents, false)} available</strong><span>of {envelopeMoney(value.ceilingCents, false)}</span></div>
      <progress value={used} max={Math.max(1, value.ceilingCents)} aria-label={`AI budget: ${envelopeMoney(value.spentCents)} used of ${envelopeMoney(value.ceilingCents, false)}`} />
      <small>{envelopeMoney(value.spentCents)} used{value.heldCents > 0 ? ` · ${envelopeMoney(value.heldCents)} reserved for work still running` : ""}</small></div></div>
    {reset && <p className="business-subtle">{reset}</p>}
    {value.kind === "trial" && value.pool && poolLeft !== null && <p className="business-subtle">Trials share a reviewed sponsor pool: {envelopeMoney(poolLeft, false)} of {envelopeMoney(value.pool.capCents, false)} left{value.pool.endsAt ? `, closing ${displayDate(value.pool.endsAt)}` : ""}.</p>}
    <p className="business-subtle">AI work is admitted against this budget before any provider is called; a request that would exceed it is declined. The same budget applies on iPhone and Studio.</p></section>;
}
