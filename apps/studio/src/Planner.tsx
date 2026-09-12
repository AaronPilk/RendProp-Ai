import { useMemo, useRef, useState } from "react";
import type { FormEvent } from "react";
import {
  CHANNELS,
  MAX_PLANS,
  bindPlanDate,
  calendarFile,
  currentTimeZone,
  downloadBlob,
  filterPlans,
  planDateChoices,
  plannerWeekStart,
  removePlan,
  savePlan,
  shiftPlannerWeek,
} from "./workspace";
import type { PlanItem } from "./workspace";
import "./planner.css";

const COMMON_ZONES = [
  "America/New_York",
  "America/Chicago",
  "America/Denver",
  "America/Los_Angeles",
  "America/Phoenix",
  "Pacific/Honolulu",
  "Europe/London",
  "Europe/Paris",
  "Asia/Tokyo",
  "Australia/Sydney",
  "UTC",
];
function displayDate(item: PlanItem): string {
  if (!item.scheduledAt || !item.timeZone)
    return `${item.date.replace("T", " at ")} · timezone not yet confirmed`;
  return new Intl.DateTimeFormat(undefined, {
    timeZone: item.timeZone,
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
    timeZoneName: "short",
  }).format(new Date(item.scheduledAt));
}

export default function Planner({
  items,
  onSave,
  onNotice,
}: {
  items: PlanItem[];
  onSave: (items: PlanItem[]) => void;
  onNotice: (message: string) => void;
}) {
  const [title, setTitle] = useState(""),
    [caption, setCaption] = useState(""),
    [date, setDate] = useState("");
  const [channel, setChannel] = useState<PlanItem["channel"]>("Instagram");
  const [timeZone, setTimeZone] = useState(currentTimeZone),
    [occurrence, setOccurrence] = useState("");
  const [editing, setEditing] = useState<PlanItem | null>(null),
    [removing, setRemoving] = useState<string | null>(null);
  const [filter, setFilter] = useState<"All" | PlanItem["channel"]>("All"),
    [view, setView] = useState<"all" | "upcoming" | "week">("all");
  const browserZone = currentTimeZone();
  const [week, setWeek] = useState(() =>
    plannerWeekStart(Date.now(), browserZone),
  );
  const titleInput = useRef<HTMLInputElement>(null);
  const dates = useMemo(() => {
    if (!date) return { choices: [] as string[], error: "" };
    try {
      const choices = planDateChoices(date, timeZone);
      return {
        choices,
        error: choices.length
          ? ""
          : "This local time does not exist because the clocks change. Choose another time.",
      };
    } catch (error) {
      return {
        choices: [] as string[],
        error:
          error instanceof Error
            ? error.message
            : "Choose a valid date and timezone.",
      };
    }
  }, [date, timeZone]);
  const visible = filterPlans(items, {
    channel: filter,
    view,
    timeZone: browserZone,
    now: Date.now(),
    weekStart: week,
  });
  function report(error: unknown, fallback: string) {
    onNotice(error instanceof Error ? error.message : fallback);
  }
  function reset() {
    setEditing(null);
    setTitle("");
    setCaption("");
    setDate("");
    setOccurrence("");
    setTimeZone(currentTimeZone());
  }
  function beginEdit(item: PlanItem) {
    const dirty = editing
      ? title !== editing.title ||
        caption !== editing.caption ||
        date !== editing.date ||
        channel !== editing.channel ||
        timeZone !== (editing.timeZone ?? browserZone) ||
        occurrence !== (editing.scheduledAt ?? "")
      : Boolean(title || caption || date);
    if (
      dirty &&
      !window.confirm(
        "Replace your unsaved form changes? Your saved post plans will remain unchanged.",
      )
    )
      return;
    setEditing(item);
    setTitle(item.title);
    setCaption(item.caption);
    setDate(item.date);
    setChannel(item.channel);
    setTimeZone(item.timeZone ?? browserZone);
    setOccurrence(item.scheduledAt ?? "");
    setRemoving(null);
    titleInput.current?.focus();
    titleInput.current?.scrollIntoView({ block: "center", behavior: "smooth" });
  }
  function save(event: FormEvent) {
    event.preventDefault();
    try {
      const binding = bindPlanDate(date, timeZone, occurrence || undefined);
      const item: PlanItem = {
        id: editing?.id ?? crypto.randomUUID(),
        createdAt: editing?.createdAt ?? new Date().toISOString(),
        title: title.trim(),
        caption,
        channel,
        ...binding,
      };
      onSave(savePlan(items, item, editing?.id ?? null));
      // Do not clear the form before the parent confirms browser storage succeeded.
      reset();
      onNotice(
        editing
          ? "Post plan updated in this browser. Any previously downloaded calendar reminder must be updated separately."
          : "Post plan saved in this browser. It has not been scheduled on social media.",
      );
    } catch (error) {
      report(error, "Could not save this post plan.");
    }
  }
  function confirmRemove(item: PlanItem) {
    try {
      onSave(removePlan(items, item.id));
      setRemoving(null);
      if (editing?.id === item.id) reset();
      onNotice(
        "Post plan removed from this browser only. Calendar reminders and social posts were not changed.",
      );
    } catch (error) {
      report(error, "Could not remove this post plan.");
    }
  }
  function exportReminder(item: PlanItem) {
    try {
      downloadBlob(
        new Blob([calendarFile(item)], { type: "text/calendar;charset=utf-8" }),
        "rendprop-post.ics",
      );
      onNotice(
        item.timeZone
          ? "Calendar reminder downloaded. Import it into your calendar; it does not publish a post."
          : `Calendar reminder downloaded using ${browserZone}. Edit this older plan to keep that timezone for future exports.`,
      );
    } catch (error) {
      report(error, "Could not export this reminder.");
    }
  }
  return (
    <div className="planner-grid content-planner">
      <section
        className="panel planner-editor"
        aria-labelledby="planner-form-title"
      >
        <div className="section-heading">
          <h2 id="planner-form-title">
            {editing ? "Edit post plan" : "Plan your next post"}
          </h2>
          <span className="tag">Browser draft</span>
        </div>
        <p className="muted">
          Get the story ready, then export a calendar reminder and publish on
          your chosen channel.
        </p>
        {editing ? (
          <p className="planner-edit-note">
            Editing “{editing.title}”. Saving updates this plan, not a social
            post.
          </p>
        ) : null}
        <form onSubmit={save} className="stack">
          <label>
            Post title
            <input
              ref={titleInput}
              required
              maxLength={120}
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              placeholder="A fresh look at your space"
            />
          </label>
          <div className="form-row">
            <label>
              Channel
              <select
                value={channel}
                onChange={(e) =>
                  setChannel(e.target.value as PlanItem["channel"])
                }
              >
                {CHANNELS.map((c) => (
                  <option key={c}>{c}</option>
                ))}
              </select>
            </label>
            <label>
              Date &amp; time
              <input
                required
                type="datetime-local"
                value={date}
                onChange={(e) => {
                  setDate(e.target.value);
                  setOccurrence("");
                }}
                aria-describedby="planner-time-help"
              />
            </label>
          </div>
          <label>
            Timezone
            <input
              required
              maxLength={100}
              list="planner-timezones"
              value={timeZone}
              onChange={(e) => {
                setTimeZone(e.target.value);
                setOccurrence("");
              }}
              aria-describedby="planner-time-help"
              autoComplete="off"
              spellCheck={false}
            />
            <datalist id="planner-timezones">
              {[...new Set([browserZone, ...COMMON_ZONES])].map((zone) => (
                <option key={zone} value={zone} />
              ))}
            </datalist>
            <small id="planner-time-help">
              Starts with your browser’s timezone. Saved reminders keep the same
              instant if you travel. Use a city timezone such as
              America/New_York.
            </small>
          </label>
          {dates.error ? (
            <p className="planner-validation" role="status">
              {dates.error}
            </p>
          ) : null}
          {dates.choices.length > 1 ? (
            <label className="planner-time-choice">
              This clock time occurs twice
              <select
                required
                value={occurrence}
                onChange={(e) => setOccurrence(e.target.value)}
              >
                <option value="">Choose an occurrence</option>
                {dates.choices.map((instant, index) => (
                  <option key={instant} value={instant}>
                    {index === 0 ? "First" : "Second"} ·{" "}
                    {new Intl.DateTimeFormat(undefined, {
                      timeZone,
                      hour: "numeric",
                      minute: "2-digit",
                      timeZoneName: "shortOffset",
                    }).format(new Date(instant))}
                  </option>
                ))}
              </select>
              <small>
                The clocks move back on this date. Choose which reminder you
                mean.
              </small>
            </label>
          ) : null}
          <label>
            Caption
            <textarea
              rows={6}
              maxLength={2200}
              value={caption}
              onChange={(e) => setCaption(e.target.value)}
              placeholder="What should your audience know?"
            />
            <small>
              {caption.length}/2,200 · Check facts and disclosures before
              publishing.
            </small>
          </label>
          <div className="planner-form-actions">
            <button
              className="primary"
              type="submit"
              disabled={
                Boolean(dates.error) || (!editing && items.length >= MAX_PLANS)
              }
            >
              {editing ? "Save changes" : "Save post plan"}
            </button>
            {editing ? (
              <button type="button" onClick={reset}>
                Cancel editing
              </button>
            ) : null}
          </div>
          {!editing && items.length >= MAX_PLANS ? (
            <p className="planner-validation" role="status">
              This workspace has 100 browser-local plans. Edit or remove one
              before adding another.
            </p>
          ) : null}
        </form>
      </section>
      <section
        className="panel planner-queue"
        aria-labelledby="planner-queue-title"
      >
        <div className="section-heading">
          <h2 id="planner-queue-title">Your content queue</h2>
          <span className="count">
            {items.length}/{MAX_PLANS}
          </span>
        </div>
        <p className="muted small">
          Plans stay in this browser and workspace. Social accounts are not
          connected; these are not automatically published.
        </p>
        <div className="planner-filters">
          <label>
            Filter channel
            <select
              value={filter}
              onChange={(e) => {
                setFilter(e.target.value as typeof filter);
                setRemoving(null);
              }}
            >
              <option value="All">All channels</option>
              {CHANNELS.map((c) => (
                <option key={c}>{c}</option>
              ))}
            </select>
          </label>
          <label>
            Show
            <select
              value={view}
              onChange={(e) => {
                setView(e.target.value as typeof view);
                setRemoving(null);
              }}
            >
              <option value="all">All plans</option>
              <option value="upcoming">Upcoming</option>
              <option value="week">Calendar week</option>
            </select>
          </label>
        </div>
        {view === "week" ? (
          <div className="planner-week">
            <div className="planner-week-buttons">
              <button
                aria-label="Previous week"
                onClick={() => {
                  setWeek(shiftPlannerWeek(week, -1));
                  setRemoving(null);
                }}
              >
                ←
              </button>
              <button
                onClick={() => {
                  setWeek(plannerWeekStart(Date.now(), browserZone));
                  setRemoving(null);
                }}
              >
                This week
              </button>
              <button
                aria-label="Next week"
                onClick={() => {
                  setWeek(shiftPlannerWeek(week, 1));
                  setRemoving(null);
                }}
              >
                →
              </button>
            </div>
            <p>
              Week of {week}
              <small>Monday–Sunday · {browserZone}</small>
            </p>
          </div>
        ) : null}
        <p className="planner-result-count" aria-live="polite">
          {visible.length} {visible.length === 1 ? "plan" : "plans"} shown
          {view === "upcoming" ? ` · ${browserZone}` : ""}
        </p>
        {visible.length === 0 ? (
          <div className="empty-inline">
            <span className="empty-glyph">↗</span>
            <h3>
              {items.length
                ? "No plans in this view."
                : "A little planning. A lot more presence."}
            </h3>
            <p>
              {items.length
                ? "Try another channel or show all plans."
                : "Your next post starts here."}
            </p>
            {items.length ? (
              <button
                onClick={() => {
                  setFilter("All");
                  setView("all");
                }}
              >
                Show all plans
              </button>
            ) : null}
          </div>
        ) : (
          <div className="planned-items">
            {visible.map((item) => (
              <article
                className={`planned-item${editing?.id === item.id ? " is-editing" : ""}`}
                key={item.id}
              >
                <span className="tag">{item.channel}</span>
                <h3>{item.title}</h3>
                <time dateTime={item.scheduledAt ?? item.date}>
                  {displayDate(item)}
                </time>
                {!item.timeZone ? (
                  <p className="planner-legacy">
                    Older local-time draft. Edit to confirm its timezone before
                    you travel or the clocks change.
                  </p>
                ) : null}
                <p>{item.caption}</p>
                <div className="button-row">
                  <button onClick={() => beginEdit(item)}>Edit plan</button>
                  <button onClick={() => exportReminder(item)}>
                    Calendar reminder
                  </button>
                  <button
                    onClick={() => {
                      try {
                        void navigator.clipboard.writeText(item.caption).then(
                          () => onNotice("Caption copied."),
                          () =>
                            onNotice(
                              "Clipboard access unavailable. Select and copy the caption above.",
                            ),
                        );
                      } catch {
                        onNotice(
                          "Clipboard access unavailable. Select and copy the caption above.",
                        );
                      }
                    }}
                  >
                    Copy caption
                  </button>
                  <button
                    className="planner-remove"
                    onClick={() => setRemoving(item.id)}
                  >
                    Remove plan
                  </button>
                </div>
                {removing === item.id ? (
                  <div
                    className="planner-remove-confirm"
                    role="group"
                    aria-label={`Remove local plan ${item.title}`}
                  >
                    <h4>Remove this local plan?</h4>
                    <p>
                      Only “{item.title}” in this browser workspace will be
                      removed. Downloaded calendar reminders, listing media, and
                      social posts will not change.
                    </p>
                    <div className="button-row">
                      <button onClick={() => setRemoving(null)}>
                        Keep plan
                      </button>
                      <button
                        className="planner-remove"
                        onClick={() => confirmRemove(item)}
                      >
                        Confirm remove
                      </button>
                    </div>
                  </div>
                ) : null}
              </article>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}
