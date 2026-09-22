import { createRoot } from "react-dom/client";
import App from "./App";
import "./styles.css";

// Avoid a dev-only double mount concealing abandoned media/identity work.
createRoot(document.getElementById("root")!).render(<App />);
