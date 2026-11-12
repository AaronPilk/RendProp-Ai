import { safeTourLinks, type TourShareProof } from "./share-link";
/** Generated on this device; the listing URL is never sent to a QR service. */
export async function createTourQR(slug: string, kind: "branded" | "unbranded" = "branded", resolved?: TourShareProof): Promise<string> {
  const selected = safeTourLinks(slug, resolved);
  if (!selected) throw new Error("This tour’s link could not be verified.");
  const { default: qrcode } = await import("qrcode-generator");
  const code = qrcode(0, "M"); code.addData(selected[kind]); code.make();
  return code.createSvgTag({ cellSize: 12, margin: 48, scalable: true });
}
export async function downloadTourQR(slug: string, kind: "branded" | "unbranded" = "branded", resolved?: TourShareProof, currentContext?: () => boolean): Promise<void> {
  if (currentContext && !currentContext()) throw new Error("Your property selection changed. Reopen it before downloading a QR code.");
  const svg = await createTourQR(slug, kind, resolved);
  if (currentContext && !currentContext()) throw new Error("Your property selection changed. Reopen it before downloading a QR code.");
  const url = URL.createObjectURL(new Blob([svg], { type: "image/svg+xml" }));
  const link = document.createElement("a"); link.href = url; link.download = `rendprop-${kind}-${slug}-qr.svg`;
  document.body.append(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url), 30_000);
}
