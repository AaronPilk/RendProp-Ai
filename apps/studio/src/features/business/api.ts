import type { StudioServices } from "../../data/services";
import type { Workspace } from "../../data/contracts";
import { uuid } from "../../data/contracts";
import {
  brandPayload, decodeAccount, decodeCompliance, decodeInviteResults, decodeLead, decodeLeads, decodeNotifications,
  decodeOverview, decodeTeam, inviteEmails, leadStatuses, record,
  type Brand, type LeadStatus, type Notifications,
} from "./model";

export function businessApi(services: Pick<StudioServices, "api">, workspace: Workspace) {
  const orgId = workspace.org.id;
  const call = (path: string, options: Omit<Parameters<StudioServices["api"]>[1], "orgId"> = {}) => services.api(`/functions/v1/${path}`, { ...options, orgId });
  return {
    account: async (signal?: AbortSignal) => decodeAccount(await call("me", { signal }), workspace),
    leads: async (filters: { listingId?: string; status?: LeadStatus; since?: string }, signal?: AbortSignal) => {
      const query = new URLSearchParams({ limit: "500" });
      if (filters.listingId) query.set("listing_id", uuid(filters.listingId));
      if (filters.status) {
        if (!(leadStatuses as readonly string[]).includes(filters.status)) throw new Error("Choose a lead status.");
        query.set("status", filters.status);
      }
      if (filters.since) query.set("since", new Date(filters.since).toISOString());
      return decodeLeads(await call(`leads?${query}`, { signal }));
    },
    setLeadStatus: async (id: string, status: LeadStatus, signal?: AbortSignal) => {
      if (!(leadStatuses as readonly string[]).includes(status)) throw new Error("Choose a lead status.");
      return decodeLead(record(await call(`leads/${uuid(id)}`, { method: "PATCH", body: { status }, signal })).lead);
    },
    team: async (signal?: AbortSignal) => decodeTeam(await call("team", { signal }), orgId),
    invite: async (addresses: string, role: string, signal?: AbortSignal) => {
      if (!["admin", "agent", "marketing"].includes(role)) throw new Error("Choose an invited team member's role.");
      const emails = inviteEmails(addresses), bulk = emails.length > 1;
      const body = bulk ? { emails, role } : { role, ...(emails[0] ? { email: emails[0] } : {}) };
      return decodeInviteResults(await call(bulk ? "team/invites/bulk" : "team/invites", { method: "POST", body, signal }), bulk);
    },
    revokeInvite: async (id: string, signal?: AbortSignal) => call(`team/invites/${uuid(id)}`, { method: "DELETE", signal }),
    removeMember: async (id: string, signal?: AbortSignal) => call(`team/members/${uuid(id)}`, { method: "DELETE", signal }),
    join: async (value: string, signal?: AbortSignal) => {
      const code = value.trim().toUpperCase().replace(/[\s-]/g, "");
      if (!/^[A-Z0-9]{12}$/.test(code)) throw new Error("Enter the 12-character invite code from your team.");
      const r = record(await call("team/accept", { method: "POST", body: { code }, signal }));
      if (r.ok !== true) throw new Error("The invite could not be accepted. Refresh your workspaces.");
      return uuid(r.org_id);
    },
    saveBrand: async (brand: Brand, signal?: AbortSignal) => call("me/brand", { method: "PATCH", body: brandPayload(brand), signal }),
    saveNotifications: async (preferences: Notifications, signal?: AbortSignal) => decodeNotifications(record(await call("me/notifications", { method: "PATCH", body: preferences, signal })).notifications),
    overview: async (window: "7d" | "30d" | "90d", signal?: AbortSignal) => {
      if (!["7d", "30d", "90d"].includes(window)) throw new Error("Choose an overview period.");
      return decodeOverview(await call(`team/overview?window=${window}`, { signal }), orgId);
    },
    compliance: async (filters: { listingId?: string; scope: "user" | "org"; from?: string; to?: string }, signal?: AbortSignal) => {
      const q = new URLSearchParams({ scope: filters.scope, limit: "5000" });
      if (filters.listingId) q.set("listing_id", uuid(filters.listingId));
      if (filters.from) q.set("from", new Date(`${filters.from}T00:00:00.000Z`).toISOString());
      if (filters.to) {
        const end = new Date(`${filters.to}T00:00:00.000Z`); end.setUTCDate(end.getUTCDate() + 1); q.set("to", end.toISOString());
      }
      return decodeCompliance(await call(`me/compliance?${q}`, { signal, maxResponseBytes: 12 * 1024 * 1024 }), orgId);
    },
    labelProvenance: async (id: string, label: string, signal?: AbortSignal) => {
      if (!label.trim() || label.trim().length > 80) throw new Error("Use a label of 1–80 characters.");
      return call(`me/compliance/${uuid(id)}`, { method: "PATCH", body: { label: label.trim() }, signal });
    },
    deleteAccount: async (confirmation: string, signal?: AbortSignal) => {
      if (confirmation !== "DELETE MY ACCOUNT") throw new Error("Type DELETE MY ACCOUNT to confirm.");
      const r = record(await call("me", { method: "DELETE", signal, timeoutMs: 120_000 }));
      if (typeof r.ok !== "boolean" || typeof r.cleanup_complete !== "boolean" || typeof r.manual_review_required !== "boolean") throw new Error("The deletion request was sent. Its result could not be read; contact support before trying again.");
      return { accountDeleted: r.ok, complete: r.cleanup_complete, needsSupport: r.manual_review_required, requestId: uuid(r.deletion_request_id) };
    },
  };
}
export type BusinessApi = ReturnType<typeof businessApi>;
