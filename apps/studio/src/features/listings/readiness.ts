import type { Listing, ListingMedia, Workspace } from "../../data/contracts";
import type { FeatureId } from "../home/features";
import { canPublishAsset, tourLinks } from "./model";
import type { ListingState } from "./model";

export type ListingDestination = { tab: "media" | "tour" | "details" } | { feature: FeatureId } | { refresh: true };
type Action = { label: string; destination: ListingDestination; requiresWrite?: boolean };
type StepStatus = "saved" | "optional" | "review" | "waiting" | "live";
export type ListingFinishStep = { id: string; title: string; detail: string; status: StepStatus; action: Action };
export type ListingFinish = {
  title: string;
  detail: string;
  next: Action | null;
  steps: ListingFinishStep[];
  publishedLinks: ReturnType<typeof tourLinks>;
  progress: number | null;
  checking: boolean;
};
const terminal = new Set(["ready", "failed", "completed", "published", "cancelled"]);
export function canEditListing(workspace: Workspace): boolean {
  const role = workspace.memberships.find(member => member.orgId === workspace.org.id)?.role;
  return role === "owner" || role === "admin" || role === "agent";
}

/** Readiness is a projection of loaded records, never an approval or publish command. */
export function listingFinish(input: {
  listing: Listing; state: ListingState; media: ListingMedia | null;
  loading: boolean; loadFailed: boolean; pendingUploads: number;
  canWrite: boolean; hasCreativeTools: boolean;
}): ListingFinish {
  const { listing, state, media, canWrite } = input;
  const tab = (label: string, value: "media" | "tour" | "details"): Action => ({ label, destination: { tab: value } });
  if (input.loadFailed || state.nextOffset !== null || media?.nextOffset != null) return {
    title: "Check the latest property status", detail: "Some property information could not be loaded. Refresh before deciding what is ready to share.",
    next: { label: "Reload listing status", destination: { refresh: true } }, steps: [], publishedLinks: null, progress: null, checking: false,
  };
  if (input.loading || !media) return {
    title: "Checking your saved work…", detail: "Loading this property's uploads, results and published tours.",
    next: null, steps: [], publishedLinks: null, progress: null, checking: true,
  };
  const assets = state.assets.filter(asset => asset.uploaded === true && asset.id !== listing.details.floorplan_asset_id);
  const photoIds = new Set([...assets.filter(asset => asset.kind === "photo").map(asset => asset.id), ...media.photos.filter(photo => photo.id !== listing.details.floorplan_asset_id).map(photo => photo.id)]);
  const videoIds = new Set([...assets.filter(asset => asset.kind === "video").map(asset => asset.id), ...media.videos.map(video => video.id)]);
  const hasPhotos = photoIds.size > 0, hasVideos = videoIds.size > 0;
  const hasMedia = hasPhotos || hasVideos;
  const hasDetails = Boolean(listing.address?.trim());
  const review = assets.filter(asset => !canPublishAsset(asset));
  const active = state.jobs.filter(job => !terminal.has(job.status));
  const failures = state.jobs.filter(job => job.status === "failed");
  const latestPublished = state.renders.filter(render => Boolean(render.published_at) && tourLinks(render.slug))
    .sort((a, b) => String(b.published_at).localeCompare(String(a.published_at)))[0];
  const links = latestPublished ? tourLinks(latestPublished.slug) : null;
  const finishedVideo = assets.some(asset => asset.kind === "video" && asset.bucket === "renders" && canPublishAsset(asset));
  const readyJob = state.jobs.some(job => job.status === "ready" && !state.renders.some(render => render.job_id === job.id && render.published_at) && assets.some(asset => asset.id === job.capture_asset_id && canPublishAsset(asset)));
  const mediaDetail = [hasPhotos ? "Photos saved" : "", hasVideos ? "Video saved" : ""].filter(Boolean).join(" · ");
  const steps: ListingFinishStep[] = [
    { id: "details", title: "Check property details", status: hasDetails ? "saved" : "waiting", detail: hasDetails ? "Details are saved. Check the address, price and facts before sharing." : "Add a property name or address. Other facts can be added when you know them.", action: tab("Review details", "details") },
    { id: "media", title: "Add photos or video", status: input.pendingUploads || media.unavailableCount ? "waiting" : hasMedia ? "saved" : "waiting", detail: input.pendingUploads ? `${input.pendingUploads} upload${input.pendingUploads === 1 ? "" : "s"} still need to finish.` : media.unavailableCount ? `${media.unavailableCount} media item${media.unavailableCount === 1 ? " needs" : "s need"} a fresh upload. Other available media can still be used.` : hasMedia ? `${mediaDetail}. Continue with these files on either device.` : "Import files here or finish an upload in the phone app. A walkthrough is optional.", action: tab(hasMedia ? "View media" : canWrite ? "Add media" : "View media", "media") },
    { id: "create", title: "Polish photos or make a reel", status: "optional", detail: "Optional. Use your existing photos and clips; no new camera capture is required.", action: input.hasCreativeTools ? { label: "Open Reel Studio", destination: { feature: "reel" }, requiresWrite: true } : tab("View your media", "media") },
    { id: "review", title: "Review your results", status: "review", detail: review.length ? `${review.length} generated result${review.length === 1 ? " needs" : "s need"} the existing property-accuracy review before publishing.` : "Check the images, video, captions and any staging disclosure. Saved files alone do not mean they have been reviewed.", action: review.length && input.hasCreativeTools ? { label: "Open accuracy review", destination: { feature: "animate" }, requiresWrite: true } : tab("Review media", "media") },
    { id: "share", title: hasVideos || links ? "Publish and share" : "Download and share", status: links ? "live" : "waiting", detail: links ? "A published tour is available. New edits and unfinished jobs do not replace it automatically here." : hasPhotos && !hasVideos ? "Review and open your photos in Media to save them. Make a reel only if you want one." : finishedVideo || readyJob ? "A finished video is available. Review it and the property details before choosing Publish." : "Your links appear after a tour is published. You can also open and save available photos from Media.", action: tab(links ? "View sharing options" : hasPhotos && !hasVideos ? "Review and download photos" : "Open publishing", hasPhotos && !hasVideos && !links ? "media" : "tour") },
  ];
  let title = "Start with the property details", detail = steps[0].detail, next: Action = steps[0].action;
  let progress: number | null = null;
  if (hasDetails) {
    if (input.pendingUploads) { title = "Finish your interrupted uploads"; detail = steps[1].detail; next = tab("View unfinished uploads", "media"); }
    else if (links) { title = "Your tour is live"; detail = "Open the published version or choose its marketing and MLS links. Review any new work before publishing it."; next = steps[4].action; }
    else if (review.length) { title = "Check the generated results"; detail = steps[3].detail; next = canWrite ? steps[3].action : tab("View results needing review", "media"); }
    else if (active.length) {
      title = "Your tour is being prepared"; detail = `${active.length} render${active.length === 1 ? " is" : "s are"} still in progress. Check the result when processing finishes.`; next = tab("View render progress", "tour");
      const values = active.map(job => Number.isFinite(job.progress) ? Math.max(0, Math.min(1, job.progress > 1 ? job.progress / 100 : job.progress)) : 0);
      progress = values.reduce((sum, value) => sum + value, 0) / values.length;
    }
    else if (readyJob || finishedVideo) { title = "Your finished video is ready to review"; detail = steps[4].detail; next = tab(canWrite ? "Review before publishing" : "View finished video", "tour"); }
    else if (failures.length) { title = "A render needs attention"; detail = "Open the failed job to see what happened. Your saved source media is still available; this guide will not retry or charge you."; next = tab("View render issue", "tour"); }
    else if (hasPhotos && !hasVideos) { title = "Your photos are ready to review"; detail = "Check the gallery, choose your cover and save the photos you want to share. A reel, floor plan and 3D walkthrough are optional."; next = steps[4].action; }
    else if (hasVideos) { title = "Choose how to finish your video"; detail = "Review your uploaded footage, build a reel, or open tour publishing. Creating a new render is always a separate choice."; next = input.hasCreativeTools && canWrite ? steps[2].action : tab("View video options", "tour"); }
    else { title = "Add the property's photos or video"; detail = steps[1].detail; next = steps[1].action; }
  }
  if (listing.status === "archived" || listing.soldAt) {
    title = listing.soldAt ? "This property is marked sold" : "This property is archived";
    detail = links ? "Its existing tour is still published. Review its sharing options or update the property status in Details." : "Your saved work remains available. Review the property status before creating new marketing.";
    next = links ? steps[4].action : tab("View property status", "details");
  }
  return { title, detail, next, steps, publishedLinks: links, progress, checking: false };
}
