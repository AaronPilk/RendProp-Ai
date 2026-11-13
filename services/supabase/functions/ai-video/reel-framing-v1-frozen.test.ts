// Frozen v1 camera texts: the profile behind rejected job c40f4860 and every
// pending v1 recipe. A new camera profile must be a new builder, never an edit.
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { buildPhotoPreservingReelPrompt, buildPropertyCanvasReelPrompt } from "./reel-framing.ts";

const hex = async (text: string) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text))))
  .map((b) => b.toString(16).padStart(2, "0")).join("");

// SHA-256 at 08fabe6 (scene noun "home", as the property worker sends).
const FROZEN: Record<string, string> = {
  "fly_through photo": "09c574e0802d406426f081579170dcf27844cf20d7111d8d777398dfaf11dbd3",
  "fly_through 16:9": "928e9af7c13b4ca1dfed1d85b078e4e69ca01c462190dfc6c9a11c34b2089842",
  "fly_through 9:16": "3048bd17573071b4939360fd7969bae8f0e1661a83307954f734fc32f70a3290",
  "push_in photo": "7d316359e73e2a58934b4ad95518734172115e9274e2af8f12e6367320250e6d",
  "push_in 16:9": "d4d17b751300c986d9a9a9ca623b874b1b82c4802f3f22c20b67b5e1117f78e5",
  "push_in 9:16": "ab21daf71755a83682580abae9e8af25cba8ac240b6669b6081fad9345395a89",
  "side_glide photo": "9b92779893cacdbf7ff0ccf8e1e4761fbd91e749d73b6c51b3127e92d9081290",
  "side_glide 16:9": "0c60910e19c68e7a4e679ea3542affb57ec0e07dd0729c393399a03fb3f9b2ec",
  "side_glide 9:16": "5defa194915ef02c247206ae0481bea16edefc986b8741676a420e3a4376d138",
  "pull_back photo": "f6e8906ad3a945e40f736cd3d15ef3a7bb4a8cabc56a39df3d1ba1701fa2ae79",
  "pull_back 16:9": "37482f11a5abccd9eb3cd862206d88033678589c2c780fb071c155b9b2b565e7",
  "pull_back 9:16": "3cbd71689281b59cec1d2d42eb8b623640eb58f513d4fcf48d235c602b6a2d3d",
};

Deno.test("all twelve v1 reel camera texts are byte-for-byte frozen", async () => {
  for (const motion of ["fly_through", "push_in", "side_glide", "pull_back"] as const) {
    assertEquals(await hex(buildPhotoPreservingReelPrompt("home", motion)), FROZEN[`${motion} photo`], motion);
    for (const aspect of ["16:9", "9:16"] as const) {
      assertEquals(await hex(buildPropertyCanvasReelPrompt("home", motion, aspect)), FROZEN[`${motion} ${aspect}`], `${motion} ${aspect}`);
    }
  }
});
