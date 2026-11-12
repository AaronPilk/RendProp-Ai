import { lazy, useState } from "react";
import { createRoot } from "react-dom/client";
import { SafeLoad, STUDIO_ROOT_OPTIONS } from "../src/StudioBoundary";
import "../src/styles.css";

const Workspace = lazy(() => import("./recovery-lazy"));
function PrivateError() {
  throw new Error("https://fixture.invalid/private/output?signature=SYNTHETIC_PRIVATE_URL_SENTINEL");
}
function Fixture() {
  const [scope, setScope] = useState("first");
  return <main><h1>Isolated recovery check</h1><button onClick={() => setScope("second")}>Change fixture workspace</button>
    <button onClick={() => setScope("private-error")}>Throw synthetic private error</button>
    <SafeLoad resetKey={scope} fallback={<p>Opening fixture…</p>}>
      {scope === "first" ? <Workspace /> : scope === "private-error" ? <PrivateError /> : <p>Second fixture workspace opened</p>}
    </SafeLoad>
    <p>Saved synthetic draft: {localStorage.getItem("rendprop.recovery.synthetic") ?? "none"}</p>
  </main>;
}
createRoot(document.getElementById("root")!, STUDIO_ROOT_OPTIONS).render(<Fixture />);
