import {
  assert,
  assertEquals,
  assertRejects,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  contactInput,
  resolveContactPhoto,
  saveClientContact,
} from "./client-contact.ts";
const USER = "c0100101-0000-4000-8000-000000000001",
  ORG = "c0100101-0000-4000-8000-000000000002",
  LISTING = "c0100101-0000-4000-8000-000000000003",
  PHOTO = "c0100101-0000-4000-8000-000000000004";
const input = () => ({
  expected_revision: 0,
  enabled: true,
  public_card: { name: "Client Agent", email: "public@fixture.invalid" },
  recipient_email: " Private@Fixture.Invalid ",
  hide_rendprop_branding: true,
  photo_asset_id: null,
});
Deno.test("client settings keep public email separate from normalized lead email", () => {
  const result = contactInput(input());
  assertEquals(result.public_card.email, "public@fixture.invalid");
  assertEquals(result.recipient_email, "private@fixture.invalid");
});
Deno.test("disable preserves saved contact for switching back", () => {
  const result = contactInput({ ...input(), enabled: false });
  assertEquals(result.public_card.name, "Client Agent");
  assertEquals(result.recipient_email, "private@fixture.invalid");
});
Deno.test("client contact rejects arbitrary avatar and private fields in public card", () => {
  for (
    const card of [{
      name: "Client",
      avatar_url: "https://other.invalid/photo.jpg",
    }, { name: "Client", recipient_email: "private@fixture.invalid" }]
  ) assertThrows(() => contactInput({ ...input(), public_card: card }));
});
Deno.test("client contact refuses incomplete routing and invalid external links", () => {
  for (
    const patch of [
      { recipient_email: "" },
      { public_card: {} },
      { public_card: { name: "email@fixture.invalid" } },
      { public_card: { name: "Client", website: "javascript:alert(1)" } },
      { public_card: { name: "Client", phone: "hello" } },
      { photo_asset_id: "not-an-asset" },
      { expected_revision: -1 },
      { public_card: { name: "Client\nInjected" } },
    ]
  ) assertThrows(() => contactInput({ ...input(), ...patch }));
});
Deno.test("contact save binds verified actor/workspace and revision RPC", async () => {
  let call: any;
  const admin = {
    rpc: async (name: string, args: unknown) => {
      call = { name, args };
      return { data: null, error: null };
    },
  };
  await saveClientContact(admin, USER, ORG, LISTING, input());
  assertEquals(call.name, "listing_client_contact_put");
  assertEquals(call.args.p_user, USER);
  assertEquals(call.args.p_org, ORG);
  assertEquals(call.args.p_listing, LISTING);
  assertEquals(call.args.p_expected_revision, 0);
  assertEquals(call.args.p_recipient_email, "private@fixture.invalid");
});
Deno.test("contact conflicts remain 409 and upstream errors do not expose database text", async () => {
  for (
    const message of ["RP409: contact changed", "sensitive provider capability"]
  ) {
    const err = await assertRejects(() =>
      saveClientContact(
        { rpc: () => Promise.resolve({ data: null, error: { message } }) },
        USER,
        ORG,
        LISTING,
        input(),
      )
    );
    assertEquals((err as any).status, message.startsWith("RP409") ? 409 : 503);
    assert(!(err as Error).message.includes("sensitive"));
  }
});
Deno.test("unavailable and wrong-listing headshots never gain public URLs", async () => {
  for (
    const asset of [null, {
      id: PHOTO,
      listing_id: LISTING,
      kind: "video",
      bucket: "renders",
      storage_key: `renders/${ORG}/${LISTING}/contact-${PHOTO}.jpg`,
      uploaded: true,
    }, {
      id: PHOTO,
      listing_id: LISTING,
      kind: "photo",
      bucket: "renders",
      storage_key: `renders/${ORG}/${LISTING}/gallery-${PHOTO}.jpg`,
      uploaded: true,
    }]
  ) {
    let called = false;
    const query: any = {
      select: () => query,
      eq: () => query,
      maybeSingle: () => Promise.resolve({ data: asset, error: null }),
    };
    const result = await resolveContactPhoto({
      from: () => query,
      rpc: () => {
        called = true;
        throw Error("unexpected");
      },
    }, {
      org_id: ORG,
      listing_id: LISTING,
      photo_asset_id: PHOTO,
      public_card: { name: "Client", avatar_url: "untrusted" },
    });
    assertEquals(result?.public_card.avatar_url, undefined);
    assert(!called);
  }
});
Deno.test("revoked client headshot suppresses URL and all exposed lineage", async () => {
  const key = `renders/${ORG}/${LISTING}/contact-${PHOTO}.jpg`,
    asset = {
      id: PHOTO,
      kind: "photo",
      bucket: "renders",
      storage_key: key,
      uploaded: true,
    };
  const query: any = {
    select: () => query,
    eq: () => query,
    maybeSingle: () => Promise.resolve({ data: asset, error: null }),
  };
  const refs = { assets: [] as string[], keys: [] as string[] };
  const result = await resolveContactPhoto({
    from: () => query,
    rpc: () =>
      Promise.resolve({
        data: {
          assets: { [PHOTO]: false },
          renders: {},
          keys: { [key]: false },
        },
        error: null,
      }),
  }, {
    org_id: ORG,
    listing_id: LISTING,
    photo_asset_id: PHOTO,
    public_card: { name: "Client" },
  }, refs);
  assertEquals(result?.public_card.avatar_url, undefined);
  assertEquals(refs, { assets: [], keys: [] });
});
