import { belongsToLibrary, uuid, type Listing, type StudioPhoto, type Workspace } from "../../data/contracts";
import { StudioError } from "../../data/config";

/** Property-level Ask Rendprop has no live Make-a-video/Photo Studio controller
 * state. Send only this selected library property and closed progress hints. */
export function creativeCoachContext(workspace: Workspace, listing: Listing, progress: {
  photos: readonly StudioPhoto[];
  assets: readonly { listing_id: string; kind: string; uploaded: boolean }[];
  renders: readonly { listing_id: string; published_at: string | null }[];
  chapters: number;
  reels: number;
}) {
  const library = workspace.libraryOrgId ?? workspace.org.id;
  const member = workspace.memberships.find(row => row.orgId === library);
  if (!belongsToLibrary(listing, workspace) || listing.orgId !== workspace.org.id || !member ||
      !(member.canRead ?? ["owner", "admin", "agent", "marketing", "team_owner"].includes(member.role)) ||
      member.accessMode === "own" && member.libraryOwnerUserId !== workspace.user.id)
    throw new StudioError("membership-required", "Reopen your current property before asking Rendprop.");
  const selected = uuid(listing.id, "selected property");
  const count = (value: number) => Number.isSafeInteger(value) && value >= 0 ? Math.min(value, 9999) : 0;
  const photos = progress.photos.filter(row => row.listingId === selected);
  const renders = progress.renders.filter(row => row.listing_id === selected);
  return {
    screen: "listing" as const,
    selected_listing_id: selected,
    listings: [{ id: selected, title: "Selected property",
      has_video: progress.assets.some(row => row.listing_id === selected && row.kind === "video" && row.uploaded),
      room_tags: count(progress.chapters), has_tour: renders.length > 0,
      published: renders.some(row => row.published_at !== null), photos: count(photos.length),
      edits: count(photos.filter(row => row.isStaged || row.isAltered).length), reels: count(progress.reels),
    }],
  };
}
