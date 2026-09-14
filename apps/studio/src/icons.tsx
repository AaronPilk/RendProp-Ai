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
  | "link";
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
