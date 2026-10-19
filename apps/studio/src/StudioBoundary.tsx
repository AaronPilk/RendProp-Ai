import { Component, Suspense, useId } from "react";
import type { ReactNode } from "react";
import type { RootOptions } from "react-dom/client";

// React 19 logs caught errors through the root before an error boundary runs.
// Keep the shared root callback free of error messages, stacks and private URLs.
export const STUDIO_ROOT_OPTIONS: Readonly<RootOptions> = Object.freeze({
  onCaughtError() {
    console.error("Rendprop Studio could not open this workspace.");
  },
});

/** A failed lazy chunk or render must offer recovery instead of a blank app.
 * No automatic reload: that could interrupt a capture or unsaved edit. */
export class StudioBoundary extends Component<{ children: ReactNode; resetKey?: string }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  componentDidUpdate(previous: Readonly<{ children: ReactNode; resetKey?: string }>) {
    if (this.state.failed && previous.resetKey !== this.props.resetKey) this.setState({ failed: false });
  }
  render() {
    return this.state.failed ? <Recovery /> : this.props.children;
  }
}

function Recovery() {
    const titleId = useId();
    return <section className="card" role="alert" aria-labelledby={titleId}>
      <p className="eyebrow">RENDPROP STUDIO</p>
      <h2 id={titleId}>This workspace couldn’t open</h2>
      <p>Reload Studio to get the latest version. Your saved projects will still be there.</p>
      <button type="button" className="primary" onClick={() => window.location.reload()}>Reload Studio</button>
    </section>;
}

export function SafeLoad({ children, fallback, resetKey }: { children: ReactNode; fallback: ReactNode; resetKey?: string }) {
  return <StudioBoundary resetKey={resetKey}><Suspense fallback={fallback}>{children}</Suspense></StudioBoundary>;
}
