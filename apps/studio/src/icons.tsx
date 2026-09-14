export type IconName =
  | "home"
  | "film"
  | "library"
  | "calendar"
  | "settings"
  | "arrow"
  | "plus"
  | "search"
  | "folder"
  | "link" | "video" | "photos" | "sparkles" | "cube" | "floorplan" | "aerial" | "person" | "mic" | "script" | "rooms" | "phone" | "check";
const paths: Record<IconName, string> = {
  home: "M3 10 12 3l9 7v11h-6v-7H9v7H3Z",
  film: "M3 3h18v18H3ZM7 3v18M17 3v18M3 8h4m10 0h4M3 16h4m10 0h4",
  library: "M3 4h7l2 3h9v14H3Z",
  calendar: "M4 5h16v16H4ZM8 3v4m8-4v4M4 11h16",
  settings:
    "M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8M12 2v3m0 14v3M2 12h3m14 0h3M5 5l2 2m10 10 2 2M5 19l2-2M17 7l2-2",
  arrow: "M5 12h14m-6-6 6 6-6 6",
  plus: "M12 4v16M4 12h16",
  search: "M10 3a7 7 0 1 0 0 14 7 7 0 0 0 0-14m5 12 6 6",
  folder: "M3 5h7l2 3h9v12H3Z",
  link: "m10 13 4-4m-7 6-2 2a3 3 0 0 0 4 4l5-5a3 3 0 0 0-4-4m7-3 2-2a3 3 0 0 0-4-4l-5 5a3 3 0 0 0 4 4",
  video: "M3 5h12v14H3Zm12 5 6-4v12l-6-4",
  photos: "M5 3h16v15H5ZM2 7v14h15M5 15l5-5 4 4 3-3 4 4M16 7h.01",
  sparkles: "m13 2 2.6 7.4L23 12l-7.4 2.6L13 22l-2.6-7.4L3 12l7.4-2.6ZM4 2v5M1.5 4.5h5",
  cube: "m12 2 9 5v10l-9 5-9-5V7Zm0 10 9-5m-9 5L3 7m9 5v10",
  floorplan: "M3 3h18v18H3ZM3 11h8V3m0 8v6m0-2h10m-10 6v-1",
  aerial: "m2 15 8-2L17 3l3 1-5 10 6 1v2l-8 1-6 4-2-1 3-4-6 1Z",
  person: "M2 4h20v16H2ZM7 8a2 2 0 1 0 0 4 2 2 0 0 0 0-4M4 17v-1a3 3 0 0 1 6 0v1m3-8h6m-6 4h6m-6 4h4",
  mic: "M9 5a3 3 0 0 1 6 0v7a3 3 0 0 1-6 0ZM5 11v1a7 7 0 0 0 14 0v-1m-7 8v3m-4 0h8",
  script: "M5 2h10l4 4v16H5ZM15 2v5h4M8 11h8m-8 4h8m-8 4h5",
  rooms: "M3 4h18v16H3ZM3 11h7V4m0 7v9m0-7h11m-5-9v4",
  phone: "M7 2h10v20H7Zm3 3h4m-3 16h2",
  check: "m4 12 5 5L20 6",
};
export default function Icon({
  name,
  size = 22,
}: {
  name: IconName;
  size?: number;
}) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.65"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d={paths[name]} />
    </svg>
  );
}
