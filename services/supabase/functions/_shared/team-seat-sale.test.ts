import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { teamSeatSaleProducts } from "./team-seat-sale.ts";

const org = "e2000000-0000-4000-8000-000000000001";
const four = "com.rendprop.app.team4.monthly";
const nine = "com.rendprop.app.team9.monthly";

Deno.test("Team seat sale list accepts only exact server-approved variants", async () => {
  const calls: unknown[] = [];
  const admin = {
    rpc(name: string, args: Record<string, string>) {
      calls.push({ name, args });
      return Promise.resolve({ data: [four, nine], error: null });
    },
  };
  assertEquals(await teamSeatSaleProducts(admin, org), [four, nine]);
  assertEquals(calls, [{
    name: "team_seat_sale_products",
    args: { p_org: org },
  }]);
});

Deno.test("Team seat sale list fails closed on dormant, unknown and malformed RPC results", async () => {
  for (
    const data of [
      null,
      {},
      [four, four],
      ["com.rendprop.app.team10.monthly"],
      [four, 9],
    ]
  ) {
    assertEquals(
      await teamSeatSaleProducts({
        rpc: () => Promise.resolve({ data, error: null }),
      }, org),
      [],
    );
  }
  assertEquals(
    await teamSeatSaleProducts({
      rpc: () =>
        Promise.resolve({ data: [four], error: { message: "offline" } }),
    }, org),
    [],
  );
  assertEquals(
    await teamSeatSaleProducts({
      rpc: () => {
        throw new Error("network unavailable");
      },
    }, org),
    [],
  );
});
