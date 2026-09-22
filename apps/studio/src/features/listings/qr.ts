import { tourLinks } from "./model";
/** Generated on this device; the listing URL is never sent to a QR service. */
export async function createTourQR(slug: string, kind: "branded" | "unbranded" = "branded"): Promise<string> {
  const links = tourLinks(slug);
  if (!links) throw new Error("This tour’s link could not be verified.");
  const { default: qrcode } = await import("qrcode-generator");
  const code = qrcode(0, "M"); code.addData(links[kind]); code.make();
  return code.createSvgTag({ cellSize: 12, margin: 48, scalable: true });
}
export async function downloadTourQR(slug: string, kind: "branded" | "unbranded" = "branded"): Promise<void> {
  const svg = await createTourQR(slug, kind);
  const url = URL.createObjectURL(new Blob([svg], { type: "image/svg+xml" }));
  const link = document.createElement("a"); link.href = url; link.download = `rendprop-${kind}-${slug}-qr.svg`;
  document.body.append(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url), 30_000);
}
