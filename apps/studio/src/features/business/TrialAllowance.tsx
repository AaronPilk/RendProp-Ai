import type { TrialUsage } from "../../data/trial";

export default function TrialAllowance({ trial }: { trial: TrialUsage }) {
  const ends = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(trial.endsAt));
  const uploadRemainingMiB = Math.max(0, Math.floor((trial.uploadBudgetBytes - trial.uploadUsedBytes) / 1_048_576));
  // Trial terms in plain words: so many AI photo edits to use within so many days.
  const days = Math.max(1, Math.round((Date.parse(trial.endsAt) - Date.parse(trial.startsAt)) / 86_400_000));
  const edits = `${trial.photoEdits.cap} AI photo edit${trial.photoEdits.cap === 1 ? "" : "s"}`;
  const meters = [
    ...(trial.walkthroughs.cap ? [{ title: "Hosted walkthrough", value: trial.walkthroughs }] : []),
    { title: "AI photo edit credits", value: trial.photoEdits },
    ...(trial.publishedListings.cap ? [{ title: "Published listing", value: trial.publishedListings }] : []),
  ];
  return <section className="business-card" aria-labelledby="trial-allowance-title">
    <h3 id="trial-allowance-title">Your trial</h3>
    <p>{trial.status === "expired" ? "Your free trial has ended. Choose a plan to keep editing." : trial.status === "exhausted" ? `You have used all ${edits} in your free trial. Choose a plan to keep editing.` : `Your free trial includes ${edits} to use within ${days} day${days === 1 ? "" : "s"}. Use them by ${ends}.`}</p>
    <div className="business-meter-grid">{meters.map(({ title, value }) => <div className="business-meter" key={title}>
      <div><strong>{title}</strong><span>{value.remaining} remaining</span></div>
      <progress value={value.used} max={value.cap} aria-label={`${title}: ${value.used} used of ${value.cap}`} />
      <small>{value.used} of {value.cap} used during this trial</small>
    </div>)}<div className="business-meter">
      <div><strong>Upload space</strong><span>{uploadRemainingMiB.toLocaleString()} MB remaining</span></div>
      <progress value={trial.uploadUsedBytes} max={trial.uploadBudgetBytes} aria-label="Trial upload space used" />
      <small>{Math.floor(trial.uploadBudgetBytes / 1_048_576).toLocaleString()} MB total for this trial, including files still uploading</small>
    </div></div>
    <p className="business-subtle">{trial.walkthroughs.cap === 0 ? "Create one listing and add your photos. Each staging, declutter, twilight, sky, lawn or custom change uses one AI photo edit. Video, aerial openings, hosted walkthroughs, and website publishing begin with a paid plan." : "Your recorded trial includes the earlier hosted walkthrough and publishing allowances shown above."}</p>
    <p className="business-subtle">These allowances are shared with your iPhone and do not reset during the trial. Your saved photos and downloads remain accessible under your account’s access and retention terms. Using the allowance does not bring Apple’s renewal date forward.</p>
    <div className="business-actions"><a href="https://apps.apple.com/us/app/id6808982413" target="_blank" rel="noopener noreferrer">Review your plan on iPhone ↗</a><a href="https://apps.apple.com/account/subscriptions" target="_blank" rel="noopener noreferrer">Manage Apple subscription ↗</a></div>
  </section>;
}
