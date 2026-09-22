import { createRoot } from "react-dom/client";
import { AppearanceSelector } from "../../src/Appearance";
import "../../src/styles.css";

// Local browser validation only. This entry has no account or service client.
createRoot(document.getElementById("root")!).render(<AppearanceSelector compact />);
