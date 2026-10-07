import { createRoot } from "react-dom/client";
import App from "./App";
import { STUDIO_ROOT_OPTIONS, StudioBoundary } from "./StudioBoundary";
import "./styles.css";

// Avoid a dev-only double mount concealing abandoned media/identity work.
createRoot(document.getElementById("root")!, STUDIO_ROOT_OPTIONS).render(<StudioBoundary><App /></StudioBoundary>);
