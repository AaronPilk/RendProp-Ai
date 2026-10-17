import os from "node:os";
import {execFileSync} from "node:child_process";

// Test-only runner inventory, captured once per suite run. On macOS it adds
// the audio device list (so a receipt says whether Chromium had a real output
// device or ran on its fake sink) and the CPU model. Only an allow-listed set
// of keys survives; anything that could be a serial number, UID, address or
// other identifier is dropped before it reaches the receipt.
const AUDIO_ITEM_KEYS = ["_name", "coreaudio_default_audio_input_device", "coreaudio_default_audio_output_device",
  "coreaudio_default_audio_system_device", "coreaudio_device_input", "coreaudio_device_output", "coreaudio_device_manufacturer",
  "coreaudio_device_srate", "coreaudio_device_transport", "coreaudio_input_source", "coreaudio_output_source"];
const MAX_AUDIO_ITEMS = 16, MAX_STRING = 120;

export function sanitizeAudioItems(items, depth = 0) {
  if (!Array.isArray(items) || depth > 2) return [];
  return items.slice(0, MAX_AUDIO_ITEMS).map(item => {
    const kept = {};
    for (const key of AUDIO_ITEM_KEYS) {
      const value = item?.[key];
      if (typeof value === "string") kept[key] = value.slice(0, MAX_STRING);
      else if (typeof value === "number" || typeof value === "boolean") kept[key] = value;
    }
    if (Array.isArray(item?._items)) kept.items = sanitizeAudioItems(item._items, depth + 1);
    return kept;
  });
}

export function quickLoad() {
  return {atIso: new Date().toISOString(), loadavg: os.loadavg(), freemem: os.freemem()};
}

export function collectRunnerFacts() {
  const facts = {capturedAtIso: new Date().toISOString(), platform: process.platform, arch: process.arch, nodeVersion: process.version,
    cpus: os.cpus().length, loadavg: os.loadavg(), totalmem: os.totalmem(), freemem: os.freemem(), issues: []};
  if (process.platform !== "darwin") return facts;
  try {
    const [ncpu, model] = execFileSync("sysctl", ["-n", "hw.ncpu", "hw.model"], {encoding: "utf8", timeout: 5000}).trim().split("\n");
    facts.hw = {ncpu: Number(ncpu), model: String(model ?? "").slice(0, MAX_STRING)};
  } catch (error) {facts.issues.push({stage: "sysctl", errorClass: error?.name ?? "Error"});}
  try {
    const report = JSON.parse(execFileSync("system_profiler", ["SPAudioDataType", "-json"], {encoding: "utf8", timeout: 20000, maxBuffer: 4 * 1024 * 1024}));
    const groups = sanitizeAudioItems(report?.SPAudioDataType);
    facts.audio = {groups, deviceCount: groups.reduce((sum, group) => sum + (group.items?.length ?? 0), 0),
      hasDefaultOutput: groups.some(group => group.items?.some(item => item.coreaudio_default_audio_output_device === "spaudio_yes"))};
  } catch (error) {facts.issues.push({stage: "system_profiler", errorClass: error?.name ?? "Error"});}
  return facts;
}
