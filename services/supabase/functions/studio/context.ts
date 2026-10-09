import type { SupabaseClient } from "npm:@supabase/supabase-js@2.116.0";
export type StudioContext = {
  userId: string;
  orgId: string;
  listingId?: string | null;
  db: SupabaseClient;
  admin: SupabaseClient;
  authorizeListing(listingId: string): Promise<void>;
};
