import {
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { saveProfileRole } from "./profile.ts";
const USER = "c0100101-0000-4000-8000-000000000001";
Deno.test("professional role write binds verified session identity", async () => {
  let called: any;
  const admin = {
    rpc: async (name: string, args: any) => {
      called = { name, args };
      return { data: { id: USER, real_estate_role: args.p_role }, error: null };
    },
  };
  const result = await saveProfileRole(admin, USER, {
    real_estate_role: "photographer_videographer",
  });
  assertEquals(called, {
    name: "set_real_estate_role",
    args: { p_user: USER, p_role: "photographer_videographer" },
  });
  assertEquals(result, {
    ok: true,
    user: { id: USER, real_estate_role: "photographer_videographer" },
  });
});
Deno.test("professional role cannot inject membership identity or permission roles", async () => {
  for (
    const body of [
      { real_estate_role: "admin" },
      { real_estate_role: "agent", user_id: "someone" },
      { real_estate_role: null },
      [],
      null,
    ]
  ) {
    let called = false;
    await assertRejects(() =>
      saveProfileRole(
        {
          rpc: () => {
            called = true;
          },
        },
        USER,
        body,
      )
    );
    assertEquals(called, false);
  }
});
