import type { TrialUsage } from "../../data/trial";

export default function TrialAllowance({ trial }: { trial: TrialUsage }) {
  const ends = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(trial.endsAt));
  const uploadRemainingMiB = Math.max(0, Math.floor((trial.uploadBudgetBytes - trial.uploadUsedBytes) / 1_048_576));
  const meters = [
    { title: "Hosted walkthrough", value: trial.walkthroughs },
    { title: "AI photo edit credits", value: trial.photoEdits },
    { title: "Published listing", value: trial.publishedListings },
  ];
  return <section className="business-card" aria-labelledby="trial-allowance-title">
    <h3 id="trial-allowance-title">Your trial</h3>
    <p>{trial.status === "expired" ? "Your trial creation window has ended." : trial.status === "exhausted" ? "You’ve used your included trial allowance." : `Use your included allowance through ${ends}.`}</p>
    <div className="business-meter-grid">{meters.map(({ title, value }) => <div className="business-meter" key={title}>
      <div><strong>{title}</strong><span>{value.remaining} remaining</span></div>
      <progress value={value.used} max={value.cap} aria-label={`${title}: ${value.used} used of ${value.cap}`} />
      <small>{value.used} of {value.cap} used during this trial</small>
    </div>)}<div className="business-meter">
      <div><strong>Upload space</strong><span>{uploadRemainingMiB.toLocaleString()} MB remaining</span></div>
      <progress value={trial.uploadUsedBytes} max={trial.uploadBudgetBytes} aria-label="Trial upload space used" />
      <small>{Math.floor(trial.uploadBudgetBytes / 1_048_576).toLocaleString()} MB total for this trial, including files still uploading</small>
    </div></div>
    <p className="business-subtle">These allowances are shared with your iPhone. Each has its own limit, so using your walkthrough does not use your photo edit credits. They do not reset during the trial.</p>
    <p className="business-subtle">Your saved photos, videos and downloads remain accessible under your account’s access and retention terms. Published links follow your hosting terms. Using the allowance does not bring Apple’s renewal date forward.</p>
    <div className="business-actions"><a href="https://apps.apple.com/us/app/id6808982413" target="_blank" rel="noopener noreferrer">Review your plan on iPhone ↗</a><a href="https://apps.apple.com/account/subscriptions" target="_blank" rel="noopener noreferrer">Manage Apple subscription ↗</a></div>
  </section>;
}
