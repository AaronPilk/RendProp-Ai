import assert from "node:assert/strict";
import test from "node:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { decodePhotoPackage } from "../src/data/photo-package";
import { PhotoPackageAllowance } from "../src/features/business/PhotoPackageAllowance";
const now=Date.parse("2026-10-07T00:00:00Z"), org="synthetic-org";
function value() { return {org_id:org,policy:"one-gemini-1k-4096-plus-one-kontext-20261007",tariff_version:"published-standard-20261006",starts_at:"2026-10-01T00:00:00Z",ends_at:"2026-11-01T00:00:00Z",photo_admissions:{cap:5,used:2,remaining:3},photo_hold_cents:35.1296,protected_photo_cents:176,other_ai:{cap_cents:38,used_cents:3,remaining_cents:35}}; }
test("funded photo metadata is optional, workspace-bound and rejects malformed costs or counters",()=>{
  assert.equal(decodePhotoPackage(null,org,now),null);assert.equal(decodePhotoPackage(undefined,org,now),null);
  const p=decodePhotoPackage({...value(),funding_id:"private"},org,now)!;assert.equal(p.photos.remaining,3);assert.equal("funding_id"in p,false);
  for (const patch of [{org_id:"foreign"},{ends_at:"2026-10-06T00:00:00Z"},{starts_at:"invalid"},{policy:"unpriced"},{tariff_version:"unpriced"},{photo_hold_cents:0},{protected_photo_cents:175},{photo_admissions:{cap:5,used:2,remaining:4}},{photo_admissions:{cap:5.5,used:2,remaining:3.5}},{other_ai:{cap_cents:38,used_cents:3,remaining_cents:38}},{other_ai:{cap_cents:38,used_cents:-1,remaining_cents:39}}])assert.throws(()=>decodePhotoPackage({...value(),...patch},org,now));
});
test("actual included allowance markup shows photo counts and separate AI balance without nominal plan promises",()=>{
  const p=decodePhotoPackage(value(),org,now)!;
  const html=renderToStaticMarkup(createElement(PhotoPackageAllowance,{value:p}));
  assert.match(html,/3 remaining/);assert.match(html,/2 \/ 5 used/);assert.match(html,/92% available/);assert.match(html,/even if generation fails/);assert.doesNotMatch(html,/100 photo|200 photo|400 photo|\$0\.35/);
  const empty=renderToStaticMarkup(createElement(PhotoPackageAllowance,{value:{...p,otherAI:{capCents:0,usedCents:0,remainingCents:0}}}));
  assert.match(empty,/Not included in this allowance/);assert.match(empty,/0% available/);
});
