import { createRoot } from "react-dom/client";
import App from "./App";
import { STUDIO_ROOT_OPTIONS, StudioBoundary } from "./StudioBoundary";
import "./styles.css";
import "./design/studio.css";
// Shared feature styles load once in a stable order; standalone browser fixtures
// import their own feature styles directly.
import "./features/listings/listings.css";
import "./features/sync/make-video.css";
import "./features/creative/creative.css";
import "./editor/conversation.css";
import "./editor/editor.css";

// Avoid a dev-only double mount concealing abandoned media/identity work.
createRoot(document.getElementById("root")!, STUDIO_ROOT_OPTIONS).render(<StudioBoundary><App /></StudioBoundary>);
