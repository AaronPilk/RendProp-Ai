import { useEffect, useId, useState } from "react";
import {
  APPEARANCE_STORAGE_KEY,
  applyAppearance,
  parseAppearance,
  readAppearance,
  saveAppearance,
} from "./theme";

export function AppearanceSelector({ compact = false, className = "" }: {
  compact?: boolean;
  className?: string;
}) {
  const id = useId();
  const [appearance, setAppearance] = useState(readAppearance);

  useEffect(() => {
    const syncPreference = (event: StorageEvent) => {
      if (event.key !== APPEARANCE_STORAGE_KEY && event.key !== null) return;
      const next = event.key === null ? "system" : parseAppearance(event.newValue);
      setAppearance(next);
      applyAppearance(next);
    };
    window.addEventListener("storage", syncPreference);
    return () => window.removeEventListener("storage", syncPreference);
  }, []);

  return (
    <label className={`appearance-selector${compact ? " is-compact" : ""} ${className}`} htmlFor={id}>
      <span>Appearance</span>
      <select id={id} value={appearance} onChange={(event) => {
        const next = parseAppearance(event.target.value);
        setAppearance(next);
        saveAppearance(next);
      }}>
        <option value="system">System</option>
        <option value="light">Light</option>
        <option value="dark">Dark</option>
      </select>
    </label>
  );
}
