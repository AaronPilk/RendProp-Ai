const variantIDs = new Set(
  Array.from(
    { length: 6 },
    (_, index) => `com.rendprop.app.team${index + 4}.monthly`,
  ),
);

/** Sale authority is an exact service-only catalog read, never a client SKU. */
export async function teamSeatSaleProducts(admin: {
  rpc(
    name: string,
    args: Record<string, string>,
  ): PromiseLike<{ data: unknown; error: unknown }>;
}, org: string): Promise<string[]> {
  try {
    const { data, error } = await admin.rpc("team_seat_sale_products", {
      p_org: org,
    });
    if (
      error || !Array.isArray(data) ||
      data.some((id) => typeof id !== "string" || !variantIDs.has(id)) ||
      new Set(data).size !== data.length
    ) return [];
    return data;
  } catch {
    return [];
  }
}
