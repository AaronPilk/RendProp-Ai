import {locateOverlay} from "./overlays";
import {decodeMedia, drawFrame, throwIfAborted, type DecodedMedia, type LocalMedia} from "./media";
import type {EditDraft} from "./model";
/** One decoded cutaway at a time. The base video and its audio never pause. */
export class OverlayPainter {
  private current: {id: string; media: DecodedMedia} | null = null;
  constructor(private draft: EditDraft, private media: Map<string, LocalMedia>, private signal: AbortSignal) {}
  async paint(canvas: HTMLCanvasElement, time: number) {
    throwIfAborted(this.signal);
    const overlay = locateOverlay(this.draft.overlays ?? [], time);
    if (this.current?.id !== overlay?.id) {this.current?.media.dispose();this.current = null;}
    if (!overlay) return;
    if (!this.current) {
      const source = this.media.get(overlay.id);
      if (!source || source.source.sha256 !== overlay.source.sha256) throw new Error(`Reselect ${overlay.source.name} before previewing or exporting this cutaway.`);
      const decoded = await decodeMedia(source.url, "image", this.signal);
      if (this.signal.aborted) {decoded.dispose();throwIfAborted(this.signal);}
      this.current = {id: overlay.id, media: decoded};
    }
    drawFrame(canvas, this.current.media, {...overlay, start:0, end:overlay.end-overlay.start, captionStyle:"clean"}, this.draft, {time, localTime:time-overlay.start});
  }
  dispose() {this.current?.media.dispose();this.current=null;}
}
