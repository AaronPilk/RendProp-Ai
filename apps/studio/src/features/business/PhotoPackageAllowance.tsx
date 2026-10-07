import type { PhotoPackage } from "../../data/photo-package";
const displayDate = (value: string) => new Intl.DateTimeFormat(undefined, { dateStyle: "medium" }).format(new Date(value));
export function PhotoPackageAllowance({ value }: { value: PhotoPackage }) {
  const percent = value.otherAI.capCents === 0 ? 0 : Math.floor(value.otherAI.remainingCents / value.otherAI.capCents * 100);
  return <section className="business-card" aria-label="Included creation allowance"><h3>Included creation allowance</h3>
    <div className="business-meter-grid"><div className="business-meter"><div><strong>Photo edits</strong><span>{value.photos.remaining} remaining</span></div>
      <progress value={value.photos.used} max={Math.max(1,value.photos.cap)} aria-label={`${value.photos.used} of ${value.photos.cap} photo edits used`} /><small>{value.photos.used} / {value.photos.cap} used</small></div>
      <div className="business-meter"><div><strong>Other AI tools</strong><span>{percent}% available</span></div><progress value={percent} max={100} aria-label={`Other AI allowance: ${percent}% available`} /><small>{value.otherAI.capCents === 0 ? "Not included in this allowance" : "Separate from your photo edits"}</small></div></div>
    <p className="business-subtle">Using other AI tools keeps your photo edits available. An accepted photo edit uses an allowance even if generation fails. This allowance ends {displayDate(value.endsAt)}.</p></section>;
}
