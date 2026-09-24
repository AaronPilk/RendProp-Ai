import {
  useCallback,
  lazy,
  Suspense,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import type { Listing, ListingMedia, SessionSnapshot, Workspace } from "./data";
import { createStudioServices, readStudioConfig } from "./data";
import type { VideoEditorProps } from "./editor/VideoEditor";
import { EDIT_LIMITS, validateDraft } from "./editor/model";
import type { EditDraft } from "./editor/model";
import type { AgentPlanHandoff, ShotPlanHandoff, CreativeEntryRequest, CreativeTool } from "./features/creative/model";
import Planner from "./Planner";
import { AppearanceSelector } from "./Appearance";
import Dashboard, { FeatureGate } from "./features/home/Dashboard";
import { homeWords, type FeatureId } from "./features/home/features";
import type { BusinessSectionRequest } from "./features/business/BusinessWorkspace";
import type { ListingEntryRequest } from "./features/listings/ListingWorkflow";
import Icon from "./icons";
import type { IconName } from "./icons";
import { INDUSTRIES, scopeKey, writePlans } from "./workspace";
import { restoreDrafts } from "./drafts";
import { canRetainWorkspace } from "./workspace-refresh";
import type { Industry, PlanItem } from "./workspace";

type Page = "overview" | "properties" | "creative" | "editor" | "library" | "planner" | "workspace";
const ListingWorkflow = lazy(() => import("./features/listings/ListingWorkflow"));
const CreativeWorkspace = lazy(() => import("./features/creative/CreativeWorkspace"));
const BusinessWorkspace = lazy(() => import("./features/business/BusinessWorkspace"));
const CloudEditor = lazy(() => import("./features/sync/PropertyReels"));
const CloudPlanner = lazy(() => import("./features/sync/CloudPlanner"));
const EditorImpl = lazy(() => import("./editor/VideoEditor"));
function VideoEditor(props: VideoEditorProps) {
  return (
    <Suspense fallback={<p role="status">Loading the video editor…</p>}>
      <EditorImpl {...props} />
    </Suspense>
  );
}
const pages: { id: Page; label: string; icon: IconName }[] = [
  { id: "overview", label: "Home", icon: "home" },
  { id: "properties", label: "My homes", icon: "folder" },
  { id: "creative", label: "AI tools", icon: "plus" },
  { id: "editor", label: "Make a reel", icon: "film" },
  { id: "library", label: "Photos & videos", icon: "library" },
  { id: "planner", label: "Content planner", icon: "calendar" },
  { id: "workspace", label: "My business", icon: "settings" },
];
const signedOut: SessionSnapshot = {
  status: "signed-out",
  identity: null,
  identityVersion: 0,
  error: null,
};
const errorMessage = (error: unknown) =>
  error instanceof Error
    ? error.message
    : "That did not finish. Please try again.";
const industryName = (key: string) =>
  INDUSTRIES[key as Industry] ?? "Your business";

// Dependency injection is a component seam, not a browser URL/environment mode.
// It lets isolated browser fixtures exercise real account transitions without
// connecting to a provider or putting test identities in the production entry.
export default function App({ servicesFactory }: {
  servicesFactory?: () => ReturnType<typeof createStudioServices>;
} = {}) {
  const setup = useMemo(() => {
    try {
      return {
        services: servicesFactory ? servicesFactory() : createStudioServices(
          readStudioConfig(import.meta.env, window.location.origin),
        ),
        error: null,
      };
    } catch (error) {
      return { services: null, error: errorMessage(error) };
    }
  }, [servicesFactory]);
  const services = setup.services;
  const [session, setSession] = useState<SessionSnapshot>(
    services?.getSnapshot() ?? signedOut,
  );
  const [page, setPage] = useState<Page>(() => {
    const view=new URL(window.location.href).searchParams.get("view");
    return pages.some(item=>item.id===view) ? view as Page : "overview";
  });
  const initialListing = useRef(new URL(window.location.href).searchParams.get("listing"));
  const [industry, setIndustry] = useState<Industry>("real_estate");
  const [storedWorkspace, setWorkspace] = useState<Workspace | null>(null);
  const [storedListings, setListings] = useState<Listing[]>([]);
  const [loadedVersion, setLoadedVersion] = useState<number | null>(null);
  const [requestedSelection, setRequestedSelection] = useState<
    { orgId: string; identityVersion: number } | undefined
  >();
  const [query, setQuery] = useState("");
  const [busy, setBusy] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [refresh, setRefresh] = useState(0);
  const [lastSynced, setLastSynced] = useState<Date | null>(null);
  const [noticeValue, setNoticeValue] = useState("");
  const [noticeScope, setNoticeScope] = useState("");
  const [showLogin, setLoginVisible] = useState(false);
  const [authBusy, setAuthBusy] = useState(false);
  const [authRedirectFailed, setAuthRedirectFailed] = useState(() => {
    const url = new URL(window.location.href);
    return url.searchParams.has("error") || new URLSearchParams(url.hash.slice(1)).has("error");
  });
  const [storedSelected, setSelected] = useState<Listing | null>(null);
  const [storedMedia, setMedia] = useState<ListingMedia | null>(null);
  const [mediaVersion, setMediaVersion] = useState<number | null>(null);
  const [mediaBusy, setMediaBusy] = useState(false);
  const [mediaError, setMediaError] = useState<string | null>(null);
  const [storedImport, setImportRequest] = useState<{
    id: string;
    files: File[];
    listingId?: string;
    sourceMedia?: {id:string;kind:"photo"|"video"}[];
  }>();
  const [importScope, setImportScope] = useState("");
  const [storedShotPlan, setStoredShotPlan] = useState<(ShotPlanHandoff & {id:string})>();
  const [shotPlanScope, setShotPlanScope] = useState("");
  const [storedAgentPlan, setStoredAgentPlan] = useState<(AgentPlanHandoff & {id:string})>();
  const [agentPlanScope, setAgentPlanScope] = useState("");
  const transfer = useRef<AbortController | null>(null);
  const [importBusy, setImportBusy] = useState(false);
  const [storedPlans, setPlans] = useState<PlanItem[]>([]);
  const [storedDraft, setDraft] = useState<EditDraft | undefined>();
  const [loadedKey, setLoadedKey] = useState("");
  const [localError, setLocalError] = useState<string | null>(null);
  const [editReadFailed, setEditReadFailed] = useState(false);
  const [plannerReadFailed, setPlannerReadFailed] = useState(false);
  const [restoreAttempt, setRestoreAttempt] = useState(0);
  const [editorOpened, setEditorOpened] = useState(false);
  const [plannerOpened, setPlannerOpened] = useState(false);
  const [creativeOpened, setCreativeOpened] = useState(false);
  const [businessOpened, setBusinessOpened] = useState(false);
  const [propertiesOpened,setPropertiesOpened]=useState(false);
  const [featureEntry, setFeatureEntry] = useState<{scope:string;creative?:CreativeEntryRequest;business?:BusinessSectionRequest;property?:ListingEntryRequest;reel?:{id:string;listingId:string};create?:string;gate?:FeatureId}>();
  const [spatialFlag,setSpatialFlag] = useState<{scope:string;enabled:boolean}>();
  const dialogRef = useRef<HTMLElement | null>(null);
  const returnFocus = useRef<HTMLElement | null>(null);
  const mediaPageAbort = useRef<AbortController | null>(null);
  const [mediaPageBusy, setMediaPageBusy] = useState(false);
  const isConnected =
    session.status === "signed-in" && !session.identity?.isAnonymous;
  const requestedOrg =
    requestedSelection?.identityVersion === session.identityVersion
      ? requestedSelection.orgId
      : undefined;
  // Rendering is fenced independently of effects: effects run after React commits.
  const workspace =
    storedWorkspace !== null &&
    isConnected &&
    loadedVersion === session.identityVersion &&
    storedWorkspace.user.id === session.identity?.userId &&
    (!requestedOrg || storedWorkspace.org.id === requestedOrg)
      ? storedWorkspace
      : null;
  const listings = workspace ? storedListings : [];
  const accountName = workspace?.user.name?.trim() || (isConnected ? "Your account" : "Sign in");
  const selected =
    workspace &&
    storedSelected?.orgId === workspace.org.id
      ? listings.find((item) => item.id === storedSelected.id) ?? null
      : null;
  const media =
    workspace &&
    selected &&
    mediaVersion === session.identityVersion &&
    storedMedia?.orgId === workspace.org.id &&
    storedMedia.listingId === selected.id
      ? storedMedia
      : null;
  const key =
    workspace && session.identity
      ? scopeKey(session.identity.userId, workspace.org.id)
      : scopeKey(null, null);
  const editScope = `${key}:${session.identityVersion}:${requestedOrg ?? "active"}`;
  const restoreScope = `${editScope}:restore:${restoreAttempt}`;
  const draftReady = loadedKey === restoreScope;
  const workspaceDraftReady =
    draftReady && (!isConnected || workspace !== null);
  const draft = draftReady ? storedDraft : undefined;
  const plans = draftReady ? storedPlans : [];
  const activeVersion = useRef("");
  activeVersion.current = editScope;
  const notice = noticeScope === editScope ? noticeValue : "";
  const importRequest = importScope === editScope ? storedImport : undefined;
  const importPlan = shotPlanScope === editScope ? storedShotPlan : undefined;
  const importAgentPlan = agentPlanScope === editScope ? storedAgentPlan : undefined;
  const entry = featureEntry?.scope === editScope ? featureEntry : undefined;
  const mediaScope = useRef("");
  mediaScope.current = `${editScope}:${selected?.id ?? ""}`;
  const presenterPending = useRef({scope: "", pending: false, busy: false});
  const presenterPendingChanged = useCallback((pending: boolean, saving = false) => {
    presenterPending.current = {scope: editScope, pending, busy: saving};
  }, [editScope]);
  function canReplacePresenter() {
    const state = presenterPending.current;
    if (state.scope !== editScope) return true;
    if (state.busy) {
      setNotice("Wait for your Creative Studio save to finish before switching.");
      return false;
    }
    return !state.pending || window.confirm("Discard unsaved Creative Studio changes?");
  }
  function setRequestedOrg(orgId: string | undefined) {
    if (orgId !== workspace?.org.id && !canReplacePresenter()) return;
    setRequestedSelection(
      orgId ? { orgId, identityVersion: session.identityVersion } : undefined,
    );
  }
  function setNotice(message: string) {
    setNoticeScope(editScope);
    setNoticeValue(message);
  }
  function selectListing(id: string, alreadyConfirmed = false) {
    if (!alreadyConfirmed && id !== selected?.id && !canReplacePresenter()) return false;
    const found = listings.find(item => item.id === id);
    // A newly created row can arrive before the workspace refresh. Preserve
    // its selection so moving from Properties to Create opens the same work.
    initialListing.current = found ? null : id;
    setSelected(found ?? null);
    return true;
  }
  function openBusiness(section: BusinessSectionRequest["section"]) {
    if (!workspace) { setShowLogin(true); return; }
    setFeatureEntry({scope:editScope,business:{id:crypto.randomUUID(),section}});
    navigate("workspace");
  }
  function openCreative(listingId:string,tool:CreativeTool) {
    if (!workspace || !listings.some(item=>item.id===listingId)) return;
    if (!canReplacePresenter()) return;
    selectListing(listingId, true);
    setFeatureEntry({scope:editScope,creative:{id:crypto.randomUUID(),listingId,tool}});
    navigate("creative");
  }
  function createProperty() {
    if (!workspace) { setShowLogin(true); return; }
    setFeatureEntry({scope:editScope,create:crypto.randomUUID()});
    navigate("properties");
  }
  function openFeature(feature:FeatureId,requestedId?:string) {
    if (!workspace) { setShowLogin(true); return; }
    if (feature === "agent") { openBusiness("brand"); return; }
    const available=listings.filter(item=>!item.soldAt);
    const target=available.find(item=>item.id===(requestedId??selected?.id))??(available.length===1?available[0]:undefined);
    if (!target) {
      if (!available.length) createProperty();
      else setFeatureEntry({scope:editScope,gate:feature});
      return;
    }
    const id=crypto.randomUUID();
    if (["tour","spatial","photos","floorplan"].includes(feature)) {
      if (!selectListing(target.id)) return;
      setFeatureEntry({scope:editScope,property:{id,listingId:target.id,tab:feature==="tour"?"tour":feature==="photos"?"media":"floorplan"}});
      navigate("properties");
    } else if(feature === "reel") {
      if (!selectListing(target.id)) return;
      setFeatureEntry({scope:editScope,reel:{id,listingId:target.id}});
      navigate("editor");
    } else {
      const tool=({studio:"photo-studio",aerial:"aerial",voice:"voiceover",copy:"shot-plans",animate:"animate",chapters:"chapters",coach:"coach",presenter:"presenter"} as Partial<Record<FeatureId,CreativeTool>>)[feature];
      if(tool)openCreative(target.id,tool);
    }
  }
  function useShotPlan(plan: ShotPlanHandoff) {
    if (!workspace || !listings.some(item => item.id === plan.listingId)) return;
    transfer.current?.abort();
    setImportRequest(undefined);
    setStoredAgentPlan(undefined);
    setShotPlanScope(editScope);
    setStoredShotPlan({...structuredClone(plan),id:crypto.randomUUID()});
    selectListing(plan.listingId);
    navigate("editor");
  }
  function useAgentPlan(plan: AgentPlanHandoff) {
    if (!workspace || !listings.some(item => item.id === plan.listingId)) return;
    transfer.current?.abort();
    setImportRequest(undefined);
    setStoredShotPlan(undefined);
    setAgentPlanScope(editScope);
    setStoredAgentPlan({...structuredClone(plan),id:crypto.randomUUID()});
    selectListing(plan.listingId);
    navigate("editor");
  }
  function setShowLogin(open: boolean) {
    if (open)
      returnFocus.current =
        document.activeElement instanceof HTMLElement
          ? document.activeElement
          : null;
    setLoginVisible(open);
  }

  useEffect(() => {
    if (!services) return;
    const unsubscribe = services.subscribe(setSession);
    void services
      .ready()
      .then(() => setSession(services.getSnapshot()))
      .catch((error) => setLoadError(errorMessage(error)));
    return () => {
      unsubscribe();
      services.dispose();
    };
  }, [services]);
  useEffect(() => {
    setRequestedSelection(undefined);
    setWorkspace(null);
    setLoadedVersion(null);
    setListings([]);
    setSelected(null);
    setMedia(null);
    setMediaVersion(null);
    setMediaError(null);
    setNotice("");
    transfer.current?.abort();
    setImportRequest(undefined);
  }, [session.identityVersion]);
  useEffect(() => {
    const controller = new AbortController();
    setLoadError(null);
    if (!services || !isConnected) {
      setBusy(false);
      return () => controller.abort();
    }
    setBusy(true);
    // Keep the same verified scope mounted while refreshing. Identity and org
    // selection already fence the rendered data; blanking this state here also
    // blanks the editor's scope and unnecessarily discards its selected files.
    const version = session.identityVersion;
    void (async () => {
      const account = await services.loadWorkspace(
        controller.signal,
        requestedOrg,
      );
      const spaces = await services.listListings(
        account.org.id,
        controller.signal,
      );
      if (
        controller.signal.aborted ||
        services.getSnapshot().identityVersion !== version
      )
        return;
      setLastSynced(new Date());
      setWorkspace(account);
      setListings(spaces);
      const requestedListing=initialListing.current;
      if(requestedListing){setSelected(spaces.find(item=>item.id===requestedListing) ?? null);initialListing.current=null;}
      setLoadedVersion(version);
      setIndustry(
        account.org.spaceType in INDUSTRIES
          ? (account.org.spaceType as Industry)
          : "other",
      );
    })()
      .catch((error) => {
        if (
          !controller.signal.aborted &&
          services.getSnapshot().identityVersion === version
        ) {
          if (!canRetainWorkspace(error)) {
            setWorkspace(null);
            setLoadedVersion(null);
            setListings([]);
            setSelected(null);
            setMedia(null);
          }
          setLoadError(errorMessage(error));
        }
      })
      .finally(() => {
        if (
          !controller.signal.aborted &&
          services.getSnapshot().identityVersion === version
        )
          setBusy(false);
      });
    return () => controller.abort();
  }, [services, isConnected, session.identityVersion, requestedOrg, refresh]);
  useEffect(() => {
    if (!workspace || initialListing.current) return;
    const url=new URL(window.location.href);
    if(selected)url.searchParams.set("listing",selected.id);else url.searchParams.delete("listing");
    window.history.replaceState(null,"",url.pathname+url.search+url.hash);
  }, [selected?.id, workspace?.org.id]);
  useEffect(() => {
    if (!isConnected) return;
    const refreshVisible = () => { if (document.visibilityState === "visible" && navigator.onLine) setRefresh(v => v + 1); };
    const timer = setInterval(refreshVisible, 30000);
    window.addEventListener("focus", refreshVisible);
    window.addEventListener("online", refreshVisible);
    document.addEventListener("visibilitychange", refreshVisible);
    return () => { clearInterval(timer); window.removeEventListener("focus", refreshVisible); window.removeEventListener("online", refreshVisible); document.removeEventListener("visibilitychange", refreshVisible); };
  }, [isConnected]);
  useEffect(() => {
    if (page === "editor") setEditorOpened(true);
    if (page === "planner") setPlannerOpened(true);
    if (page === "creative") setCreativeOpened(true);
    if (page === "workspace") setBusinessOpened(true);
    if (page === "properties") setPropertiesOpened(true);
  }, [page]);
  useEffect(() => {
    const abort=new AbortController();
    if(workspace&&services)void services.api("/functions/v1/spatial/capability",{orgId:workspace.org.id,signal:abort.signal}).then(raw=>{
      if(!abort.signal.aborted)setSpatialFlag({scope:editScope,enabled:(raw as {enabled?:boolean})?.enabled===true});
    },()=>{});
    return ()=>abort.abort();
  },[services,workspace?.org.id,editScope]);
  useEffect(() => {
    setLoadedKey("");
    setDraft(undefined);
    setPlans([]);
    setLocalError(null);
    setImportRequest(undefined);
    setStoredShotPlan(undefined);
    setStoredAgentPlan(undefined);
    transfer.current?.abort();
    const restored = restoreDrafts(() => localStorage, key);
    setDraft(restored.draft);
    setPlans(restored.plans);
    setEditReadFailed(restored.editReadFailed);
    setPlannerReadFailed(restored.plannerReadFailed);
    setLoadedKey(restoreScope);
  }, [key, editScope, restoreScope]);
  useEffect(() => {
    mediaPageAbort.current?.abort();
    setMediaPageBusy(false);
    setMedia(null);
    setMediaError(null);
    setMediaBusy(false);
    const controller = new AbortController();
    if (!selected || !workspace || !services) return () => controller.abort();
    const version = session.identityVersion;
    setMediaBusy(true);
    void services
      .listMedia(workspace.org.id, selected.id, controller.signal)
      .then((value) => {
        if (
          !controller.signal.aborted &&
          services.getSnapshot().identityVersion === version
        ) {
          setMedia(value);
          setMediaVersion(version);
        }
      })
      .catch((error) => {
        if (
          !controller.signal.aborted &&
          services.getSnapshot().identityVersion === version
        )
          setMediaError(errorMessage(error));
      })
      .finally(() => {
        if (
          !controller.signal.aborted &&
          services.getSnapshot().identityVersion === version
        )
          setMediaBusy(false);
      });
    return () => controller.abort();
  }, [services, selected, workspace, refresh]);
  useEffect(
    () => () => {
      transfer.current?.abort();
      mediaPageAbort.current?.abort();
    },
    [],
  );
  useLayoutEffect(() => {
    if (!showLogin) return;
    const dialog = dialogRef.current;
    if (!dialog) return;
    const background = Array.from(
      dialog.parentElement?.parentElement?.children ?? [],
    )
      .filter(
        (element): element is HTMLElement =>
          element instanceof HTMLElement && element !== dialog.parentElement,
      )
      .map((element) => ({ element, wasInert: element.inert }));
    background.forEach(({ element }) => {
      element.inert = true;
    });
    const focusable = () =>
      Array.from(
        dialog.querySelectorAll<HTMLElement>(
          'button:not([disabled]),a[href],input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])',
        ),
      ).filter((element) => element.getClientRects().length > 0);
    const focusFirst = () => {
      (focusable()[0] ?? dialog).focus();
    };
    focusFirst();
    const keydown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        setLoginVisible(false);
        return;
      }
      if (event.key !== "Tab") return;
      const items = focusable();
      const first = items[0],
        last = items[items.length - 1];
      if (!first || !last) {
        event.preventDefault();
        dialog.focus();
        return;
      }
      if (
        event.shiftKey &&
        (document.activeElement === first ||
          !dialog.contains(document.activeElement))
      ) {
        event.preventDefault();
        last.focus();
      } else if (
        !event.shiftKey &&
        (document.activeElement === last ||
          !dialog.contains(document.activeElement))
      ) {
        event.preventDefault();
        first.focus();
      }
    };
    const focusin = (event: FocusEvent) => {
      if (event.target instanceof Node && !dialog.contains(event.target))
        focusFirst();
    };
    document.addEventListener("keydown", keydown);
    document.addEventListener("focusin", focusin);
    return () => {
      document.removeEventListener("keydown", keydown);
      document.removeEventListener("focusin", focusin);
      background.forEach(({ element, wasInert }) => {
        element.inert = wasInert;
      });
      queueMicrotask(() => {
        if (returnFocus.current?.isConnected) returnFocus.current.focus();
      });
    };
  }, [showLogin]);
  function currentScope() {
    return (
      activeVersion.current === editScope &&
      (!services ||
        services.getSnapshot().identityVersion === session.identityVersion)
    );
  }
  function saveDraft(next: EditDraft) {
    if (!draftReady || !currentScope() || (isConnected && !workspace)) return;
    // The editor emits its initial draft on mount. A corrupt/unreadable saved
    // document remains untouched; the user can still export a temporary edit.
    if (editReadFailed) {
      setDraft(validateDraft(next));
      return;
    }
    try {
      localStorage.setItem(`${key}:edit`, JSON.stringify(validateDraft(next)));
      setDraft(next);
      setLocalError(null);
    } catch {
      setLocalError(
        "Draft not saved: browser storage is unavailable or full. Keep this tab open and export your edit.",
      );
    }
  }
  function savePlans(next: PlanItem[]) {
    if (!draftReady || !currentScope() || (isConnected && !workspace))
      throw new Error("Wait for your workspace to load.");
    if (plannerReadFailed)
      throw new Error(
        "Saved post plans could not be restored. Retry recovery first; the existing document has not been overwritten.",
      );
    writePlans(localStorage, key, next);
    setPlans(next);
  }
  function navigate(next: Page) {
    const url=new URL(window.location.href);url.searchParams.set("view",next);
    window.history.replaceState(null,"",url.pathname+url.search+url.hash);
    setPage(next);
    setNotice("");
  }
  async function connect() {
    if (!services) {
      setNotice(
        "Account connection is not configured on Studio yet. You can edit local files now.",
      );
      return;
    }
    setAuthBusy(true);
    try {
      await services.signIn();
    } catch (error) {
      setNotice(errorMessage(error));
      setAuthBusy(false);
    }
  }
  async function signOut() {
    if (!services) return;
    if (!canReplacePresenter()) return;
    setAuthBusy(true);
    transfer.current?.abort();
    try {
      await services.signOut();
      setNotice("Signed out. This browser’s local editor is still available.");
    } catch (error) {
      setNotice(errorMessage(error));
    } finally {
      setAuthBusy(false);
    }
  }
  async function loadMoreMedia() {
    if (
      !services ||
      !workspace ||
      !selected ||
      !media ||
      media.nextOffset === null ||
      mediaPageBusy
    )
      return;
    mediaPageAbort.current?.abort();
    const controller = new AbortController();
    mediaPageAbort.current = controller;
    const scope = mediaScope.current;
    const version = session.identityVersion;
    const nextOffset = media.nextOffset;
    setMediaPageBusy(true);
    setMediaError(null);
    try {
      const next = await services.listMedia(
        workspace.org.id,
        selected.id,
        controller.signal,
        nextOffset,
      );
      if (
        controller.signal.aborted ||
        mediaScope.current !== scope ||
        services.getSnapshot().identityVersion !== version
      )
        return;
      setMedia((previous) => {
        if (
          !previous ||
          previous.orgId !== next.orgId ||
          previous.listingId !== next.listingId ||
          previous.nextOffset !== nextOffset
        )
          return previous;
        const photos = [
          ...new Map(
            [...previous.photos, ...next.photos].map((item) => [item.id, item]),
          ).values(),
        ];
        const videos = [
          ...new Map(
            [...previous.videos, ...next.videos].map((item) => [item.id, item]),
          ).values(),
        ];
        return {
          ...next,
          photos,
          videos,
          unavailableCount: previous.unavailableCount + next.unavailableCount,
        };
      });
    } catch (error) {
      if (
        !controller.signal.aborted &&
        mediaScope.current === scope &&
        services.getSnapshot().identityVersion === version
      )
        setMediaError(errorMessage(error));
    } finally {
      if (mediaPageAbort.current === controller) setMediaPageBusy(false);
    }
  }
  async function importMedia(url: string, name: string, sourceMedia: {id:string;kind:"photo"|"video"}) {
    transfer.current?.abort();
    const controller = new AbortController();
    transfer.current = controller;
    const version = activeVersion.current;
    setImportBusy(true);
    // Expiring read links and stalled body streams must never pin the import UI.
    // This is a total download deadline, not a fresh allowance for each chunk.
    let timedOut = false;
    const deadline = setTimeout(() => {
      timedOut = true;
      controller.abort();
    }, 120_000);
    try {
      // A signed URL is only a read capability. Do not attach the account bearer to R2.
      const response = await fetch(url, {
        signal: controller.signal,
        credentials: "omit",
        cache: "no-store",
        referrerPolicy: "no-referrer",
        redirect: "error",
      });
      if (!response.ok || !response.body)
        throw new Error(
          "Media could not be downloaded. Refresh the library to renew its link.",
        );
      const declared = Number(response.headers.get("content-length"));
      if (declared > EDIT_LIMITS.fileBytes)
        throw new Error(
          `This file exceeds the editor’s ${EDIT_LIMITS.fileBytes / 1024 ** 2} MiB limit. Use a shorter clip or the property’s render tools.`,
        );
      const reader = response.body.getReader();
      const chunks: Uint8Array<ArrayBuffer>[] = [];
      let size = 0;
      try {
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          size += value.byteLength;
          if (size > EDIT_LIMITS.fileBytes)
            throw new Error(
              `This file exceeds the editor’s ${EDIT_LIMITS.fileBytes / 1024 ** 2} MiB limit.`,
            );
          chunks.push(new Uint8Array(value));
        }
      } finally {
        await reader.cancel().catch(() => {});
        reader.releaseLock();
      }
      if (controller.signal.aborted || version !== activeVersion.current)
        return;
      if (!currentScope()) return;
      const contentType=response.headers.get("content-type")?.split(";")[0].trim().toLowerCase() ?? "";
      const extension=({"image/png":"png","image/jpeg":"jpg","image/webp":"webp","video/mp4":"mp4","video/quicktime":"mov","video/x-m4v":"m4v"} as Record<string,string>)[contentType];
      const file = new File(chunks, extension ? name.replace(/\.[^.]+$/, `.${extension}`) : name, {
        type: contentType,
        lastModified: 0,
      });
      setImportScope(version);
      setStoredShotPlan(undefined);
      setStoredAgentPlan(undefined);
      setImportRequest({ id: crypto.randomUUID(), files: [file], listingId:selected?.id, sourceMedia:[sourceMedia] });
      navigate("editor");
      setNotice(
        "Shared media is ready in Video editor.",
      );
    } catch (error) {
      if (timedOut && currentScope())
        setNotice(
          "Media download timed out. Check your connection, refresh the library, and try again.",
        );
      else if (!controller.signal.aborted && currentScope())
        setNotice(errorMessage(error));
    } finally {
      clearTimeout(deadline);
      if (transfer.current === controller) setImportBusy(false);
    }
  }
  const filtered = listings.filter((l) =>
    `${l.address ?? ""} ${l.tagline ?? ""} ${industryName(l.spaceType)}`
      .toLowerCase()
      .includes(query.toLowerCase()),
  );
  const navigation = pages.map(item=>item.id==="properties"?{...item,label:homeWords(workspace?.org.spaceType??industry).collection}:item);
  const heading = navigation.find((p) => p.id === page)!;
  const compactLabels: Record<Page,string>={overview:"Home",properties:homeWords(workspace?.org.spaceType??industry).plural,creative:"AI tools",editor:"Reel",library:"Library",planner:"Planner",workspace:"Business"};
  return (
    <div className="studio-shell">
      <aside className="sidebar">
        <a
          className="brand"
          href="https://rendprop.com"
          aria-label="Rendprop website"
        >
          <img src="/rendprop-mark.svg" alt="" />
          <span>
            rendprop<span className="brand-sub">STUDIO</span>
          </span>
        </a>
        <div className="workspace-switch">
          <span className="workspace-avatar">
            {workspace?.org.name.slice(0, 1).toUpperCase() ?? "R"}
          </span>
          <div>
            {workspace ? <><label className="sr-only" htmlFor="switch-workspace">Switch workspace</label><select id="switch-workspace" value={workspace.org.id} onChange={e=>{transfer.current?.abort();setRequestedOrg(e.target.value);}}>{workspace.memberships.map(m=><option key={m.orgId} value={m.orgId}>{m.orgName}</option>)}</select></> : <strong>Your creative space</strong>}
            <small>{workspace ? "Connected workspace" : "Local workspace"}</small>
          </div>
        </div>
        <p className="nav-label">CREATE & GROW</p>
        <nav aria-label="Studio navigation">
          {navigation.map((item) => (
            <button
              key={item.id}
              className={`nav-item ${page === item.id ? "active" : ""}`}
              aria-label={item.label}
              aria-current={page === item.id ? "page" : undefined}
              onClick={() => navigate(item.id)}
            >
              <Icon name={item.icon} />
              <span className="nav-label-full">{item.label}</span><span className="nav-label-short" aria-hidden="true">{compactLabels[item.id]}</span>
            </button>
          ))}
        </nav>
        <div className="sidebar-bottom">
          <div className="device-card">
            <Icon name="link" />
            <strong>From phone to studio.</strong>
            <p>
              {workspace ? "Your properties and uploaded media share this workspace with your iPhone. Refresh on either device to see the latest work." : "Sign in with the account you use in Rendprop to bring your spaces with you."}
            </p>
            <button
              onClick={() =>
                isConnected ? navigate("workspace") : setShowLogin(true)
              }
            >
              {isConnected ? "Manage workspace" : "Connect your account"}
              <Icon name="arrow" size={16} />
            </button>
          </div>
          <a
            href="https://rendprop.com/privacy"
            target="_blank"
            rel="noreferrer"
          >
            Privacy
          </a>
          <a href="https://rendprop.com/terms" target="_blank" rel="noreferrer">
            Terms
          </a>
          <small className="version-label">
            Your phone. Your office. One workspace.
          </small>
        </div>
      </aside>
      <div className="main-shell">
        <header className="topbar">
          <div className="breadcrumb">
            Workspace <span>/</span> <strong>{heading.label}</strong>
          </div>
          <div className="top-actions">
            <AppearanceSelector compact/>
            <span className="connection">
              <i className={workspace ? "online" : ""} />
              {busy
                ? "Connecting…"
                : workspace
                  ? `Updated ${lastSynced?.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) ?? "just now"}`
                  : "Local mode"}
            </span>
            <button
              className="account-button"
              aria-label={isConnected ? `Manage ${accountName}` : "Sign in"}
              onClick={() =>
                isConnected ? navigate("workspace") : setShowLogin(true)
              }
            >
              <span className="account-avatar">
                {workspace?.user.name?.trim().slice(0, 1) || "↗"}
              </span>
              {accountName}
            </button>
          </div>
        </header>
        <main id="main" tabIndex={-1}>
          {authRedirectFailed && !isConnected && <div className="notice error" role="alert">
            <span>This sign-in link expired or was interrupted. Start a fresh Apple sign-in to continue.</span>
            <button onClick={() => { setAuthRedirectFailed(false); setShowLogin(true); }}>Sign in again</button>
          </div>}
          {notice && (
            <div className="notice" role="status">
              <span>{notice}</span>
              <button
                aria-label="Dismiss notification"
                onClick={() => setNotice("")}
              >
                ×
              </button>
            </div>
          )}
          {(loadError || session.error) && (
            <div className="notice error" role="alert">
              <span>
                {loadError || session.error}{" "}
                {workspace
                  ? "Your last loaded workspace is shown. Local edits are still available; retry to refresh account data."
                  : isConnected
                  ? "Switch to local mode to edit files on this device."
                  : "Your local editor is still available."}
              </span>
              {session.status === "error" ? (
                <button onClick={() => setShowLogin(true)}>
                  Sign in again
                </button>
              ) : (
                <button onClick={() => setRefresh((v) => v + 1)}>
                  Retry connection
                </button>
              )}
              {isConnected && (
                <button disabled={authBusy} onClick={() => void signOut()}>
                  Use local files
                </button>
              )}
            </div>
          )}
          {localError && (
            <div className="notice error" role="alert">
              {localError}
            </div>
          )}
          {draftReady && (editReadFailed || plannerReadFailed) && (
            <div className="notice error" role="alert">
              <span>
                {editReadFailed
                  ? "The saved video edit could not be restored. It is kept intact. New edits are temporary and will not autosave; export your work before leaving. "
                  : ""}
                {plannerReadFailed
                  ? "Saved post plans could not be restored. Existing plans are kept intact and will not be overwritten. "
                  : ""}
              </span>
              <button onClick={() => {
                if(window.confirm('Reload the saved drafts from this browser? Temporary edits and unsaved form changes will be discarded, and imported files may need to be reselected. Export any temporary work first.'))setRestoreAttempt((v) => v + 1);
              }}>
                Retry saved drafts
              </button>
            </div>
          )}
          {page !== "overview" && !(workspace && (page === "properties" || page === "creative")) && <div className="page-title">
            <div>
              <p className="eyebrow">
                {industryName(industry).toUpperCase()} / RENDPROP STUDIO
              </p>
              <h1>
{heading.label}
              </h1>
              <p className="subtitle">
                {page === "properties"
                    ? "Everything for a listing, from its first capture to the published tour."
                  : page === "creative"
                    ? "Create photos, narration, scripts, and videos for your listing."
                  : page === "editor"
                    ? "Turn your photos and footage into a story worth sharing."
                    : page === "library"
                      ? "The spaces and content from your Rendprop account."
                      : page === "planner"
                        ? "A clear plan for what comes next."
                        : "One identity. Your existing Rendprop workspace."}
              </p>
            </div>
          </div>}
          {page === "overview" && <Dashboard workspace={workspace} listings={listings} selectedId={selected?.id} busy={busy} spatialAvailable={spatialFlag?.scope===editScope&&spatialFlag.enabled} onSelect={selectListing} onFeature={openFeature} onCreate={createProperty} onProperties={()=>navigate("properties")} onLeads={()=>openBusiness("leads")} onPlanner={()=>navigate("planner")} onConnect={()=>setShowLogin(true)} onLibrary={()=>navigate("library")}/>}
          {entry?.gate && workspace && <FeatureGate feature={entry.gate} listings={listings} spaceType={workspace.org.spaceType} onChoose={id=>openFeature(entry.gate!,id)} onCancel={()=>setFeatureEntry(undefined)} onCreate={createProperty}/>}
          {(page === "properties" || propertiesOpened) && <section hidden={page !== "properties"} aria-label="Your property workspace">{workspace && services ? <Suspense fallback={<p role="status">Opening your properties…</p>}>
            <ListingWorkflow entryRequest={entry?.property} createRequest={entry?.create} onOpenFeature={openFeature} key={editScope} services={services} workspace={workspace} listings={listings} listingId={selected?.id} onChanged={() => setRefresh(v => v + 1)} onSelectListing={selectListing} />
          </Suspense> : <EmptyConnect onConnect={() => setShowLogin(true)} />}</section>}
          {(page === "creative" || creativeOpened) && <section hidden={page !== "creative"} aria-label="Creative workspace">{workspace && services ? <Suspense fallback={<p role="status">Opening creative tools…</p>}>
            <CreativeWorkspace entryRequest={entry?.creative} onOpenEditor={id=>openFeature("reel",id)} key={editScope} services={services} workspace={workspace} listings={listings} listingId={selected?.id} onChanged={() => setRefresh(v => v + 1)} onSelectListing={id => selectListing(id, true)} onUseShotPlan={useShotPlan} onUseAgentPlan={useAgentPlan} onPresenterPendingChange={presenterPendingChanged} />
          </Suspense> : <EmptyConnect onConnect={() => setShowLogin(true)} />}</section>}
          {(page === "editor" || editorOpened) && (
            <section
              hidden={page !== "editor"}
              aria-label="Video editing workspace"
            >
              {workspace && services ? <Suspense fallback={<p role="status">Opening your saved edit…</p>}>
                <CloudEditor entryRequest={entry?.reel} onOpenCreative={openCreative} key={editScope} services={services} workspace={workspace} listings={listings} listingId={selected?.id} active={page === "editor"} importRequest={importRequest} importPlan={importPlan} importAgentPlan={importAgentPlan} onChanged={()=>setRefresh(v=>v+1)} />
              </Suspense> : workspaceDraftReady ? (
                <VideoEditor
                  key={`${editScope}:${restoreAttempt}`}
                  active={page === "editor"}
                  initialDraft={draft}
                  onDraftChange={saveDraft}
                  importRequest={importRequest}
                />
              ) : (
                <p role="status">Opening this workspace’s saved edit…</p>
              )}
            </section>
          )}
          {page === "library" && (
            <>
              <div className="library-tools">
                <label className="search-field">
                  <Icon name="search" size={19} />
                  <input
                    aria-label="Search spaces"
                    placeholder="Search your spaces…"
                    value={query}
                    onChange={(e) => setQuery(e.target.value)}
                  />
                </label>
                <button
                  onClick={() => setRefresh((v) => v + 1)}
                  disabled={!workspace || busy}
                >
                  Refresh library
                </button>
                <button className="primary" onClick={() => navigate("editor")}>
                  <Icon name="plus" size={17} />
                  Use local files
                </button>
              </div>
              {!workspace ? (
                <section className="panel">
                  {busy ? (
                    <p role="status">Loading your spaces…</p>
                  ) : (
                    <EmptyConnect onConnect={() => setShowLogin(true)} />
                  )}
                </section>
              ) : (
                <div className="library-layout">
                  <section className="panel">
                    <div className="section-heading">
                      <h2>Spaces</h2>
                      <span className="count">{filtered.length}</span>
                    </div>
                    <SpaceList
                      spaces={filtered}
                      select={setSelected}
                      selectedId={selected?.id}
                    />
                  </section>
                  <section className="panel media-panel">
                    {!selected ? (
                      <div className="empty-inline">
                        <Icon name="folder" size={40} />
                        <h2>Select a space</h2>
                        <p>
                          Browse its photos and videos, then bring a clip into
                          your edit.
                        </p>
                      </div>
                    ) : (
                      <>
                        <h2>
                          {selected.address ||
                            selected.tagline ||
                            "Untitled space"}
                        </h2>
                        <p className="muted">
                          Original app media is never changed by a local edit.
                        </p>
                        {mediaBusy && <p role="status">Loading media…</p>}
                        {mediaError && (
                          <div className="notice error" role="alert">
                            {mediaError}
                            <button onClick={() => setRefresh((v) => v + 1)}>
                              Retry
                            </button>
                          </div>
                        )}
                        {media && (
                          <>
                            <div className="media-grid">
                              {media.photos.map((photo) => (
                                <article key={photo.id} className="media-card">
                                  <img
                                    src={photo.url}
                                    alt={photo.caption || "Listing photo"}
                                    loading="lazy"
                                    referrerPolicy="no-referrer"
                                  />
                                  <strong>{photo.caption || "Photo"}</strong>
                                  {photo.isStaged && (
                                    <span className="tag">
                                      Virtually staged
                                    </span>
                                  )}
                                  <button
                                    disabled={importBusy}
                                    onClick={() =>
                                      void importMedia(
                                        photo.url,
                                        `photo-${photo.id}.jpg`,
                                        {id:photo.id,kind:"photo"},
                                      )
                                    }
                                  >
                                    Use in editor
                                  </button>
                                </article>
                              ))}
                              {media.videos.map((video) => (
                                <article key={video.id} className="media-card">
                                  <video
                                    src={video.url}
                                    controls
                                    preload="none"
                                    playsInline
                                  />
                                  <strong>
                                    Video{" "}
                                    {video.durationSeconds
                                      ? `· ${Math.round(video.durationSeconds)}s`
                                      : ""}
                                  </strong>
                                  <button
                                    disabled={importBusy}
                                    onClick={() =>
                                      void importMedia(
                                        video.url,
                                        `video-${video.id}.mp4`,
                                        {id:video.id,kind:"video"},
                                      )
                                    }
                                  >
                                    Use in editor
                                  </button>
                                </article>
                              ))}
                            </div>
                            {media.photos.length + media.videos.length ===
                              0 && (
                              <p>
                                No completed, supported media found for this
                                space.
                              </p>
                            )}
                            <p className="small muted">
                              Links expire after 10 minutes. Refresh to renew.
                              Editor imports support up to {EDIT_LIMITS.fileBytes / 1024 ** 2} MiB per file.
                            </p>
                          </>
                        )}
                        {importBusy && (
                          <div className="notice" role="status">
                            Preparing your media…
                            <button onClick={() => transfer.current?.abort()}>
                              Cancel
                            </button>
                          </div>
                        )}
                      </>
                    )}
                  </section>
                </div>
              )}
            </>
          )}
          {page === "library" &&
            media &&
            (media.nextOffset !== null || media.unavailableCount > 0) && (
              <section className="panel" aria-label="Media availability">
                {media.unavailableCount > 0 && (
                  <p role="status">
                    {media.unavailableCount} saved{" "}
                    {media.unavailableCount === 1
                      ? "item cannot"
                      : "items cannot"}{" "}
                    be opened in Studio. Use the Rendprop app to review
                    these items.
                  </p>
                )}
                {media.nextOffset !== null && (
                  <button
                    disabled={mediaPageBusy}
                    onClick={() => void loadMoreMedia()}
                  >
                    {mediaPageBusy ? "Loading more media…" : "Load more media"}
                  </button>
                )}
              </section>
            )}
          {(page === "planner" || plannerOpened) && <section hidden={page !== "planner"} aria-label="Content planning workspace">
            {workspace && services ? <Suspense fallback={<p role="status">Opening saved plans…</p>}><CloudPlanner key={editScope} services={services} workspace={workspace} onNotice={setNotice}/></Suspense> : workspaceDraftReady ? (
              <Planner
                key={restoreScope}
                items={plans}
                onSave={savePlans}
                onNotice={(message) => {
                  if (currentScope()) setNotice(message);
                }}
              />
            ) : (
              <p role="status">Opening this workspace’s content plan…</p>
            )}</section>}
          {(page === "workspace" || businessOpened) && workspace && services && <section hidden={page !== "workspace"} aria-label="Business workspace"><Suspense fallback={<p role="status">Opening your business workspace…</p>}><BusinessWorkspace sectionRequest={entry?.business} key={editScope} services={services} workspace={workspace} listings={listings} listingId={selected?.id} onChanged={()=>setRefresh(v=>v+1)} onSelectListing={selectListing}/></Suspense></section>}
          {page === "workspace" && (
            <div className="settings-grid">
              <section className="panel">
                <div className="section-heading">
                  <h2>Your Rendprop account</h2>
                  <span className="tag">
                    {workspace ? "Connected" : "Local mode"}
                  </span>
                </div>
                {workspace ? (
                  <>
                    <p className="account-email">
                      {accountName}
                    </p>
                    <p className="muted">{workspace.user.email}</p>
                    <label>
                      Workspace
                      <select
                        value={workspace.org.id}
                        onChange={(e) => {
                          transfer.current?.abort();
                          setRequestedOrg(e.target.value);
                        }}
                      >
                        {workspace.memberships.map((m) => (
                          <option key={m.orgId} value={m.orgId}>
                            {m.orgName} · {m.role}
                          </option>
                        ))}
                      </select>
                    </label>
                    <dl className="account-details">
                      <div>
                        <dt>Business</dt>
                        <dd>{industryName(workspace.org.spaceType)}</dd>
                      </div>
                      <div>
                        <dt>Current plan</dt>
                        <dd>
                          {workspace.planDegraded
                            ? "Temporarily unavailable"
                            : workspace.plan}
                        </dd>
                      </div>
                      <div>
                        <dt>Spaces</dt>
                        <dd>{listings.length}</dd>
                      </div>
                    </dl>
                    <p className="muted small">
                      Plans and purchases remain managed by the existing
                      Rendprop app. Studio does not create a second
                      subscription.
                    </p>
                    <button onClick={() => void signOut()} disabled={authBusy}>
                      {authBusy ? "Signing out…" : "Sign out"}
                    </button>
                  </>
                ) : (
                  <EmptyConnect onConnect={() => setShowLogin(true)} />
                )}
              </section>
              <section className="panel">
                <h2>Publishing, without the guesswork</h2>
                <p className="muted">
                  Export a video, prepare your caption, and post it to your
                  channels. The planner can create calendar reminders today.
                </p>
                <div className="integration-list">
                  {["Instagram & Facebook", "TikTok & YouTube", "LinkedIn"].map(
                    (name) => (
                      <div key={name}>
                        <strong>{name}</strong>
                        <span className="tag">Not connected</span>
                      </div>
                    ),
                  )}
                </div>
                <p className="small muted">
                  Download your finished video and use your social app to post.
                  Saved plans and calendar reminders help you keep your schedule.
                </p>
                <button onClick={() => navigate("planner")}>
                  Open content planner
                  <Icon name="arrow" size={16} />
                </button>
              </section>
            </div>
          )}
          <footer className="workspace-footer">
            <span>Made for the spaces worth sharing.</span>
            <span>
              Rendprop Studio <i>✦</i>
            </span>
          </footer>
        </main>
      </div>
      {showLogin && (
        <div
          className="modal-backdrop"
          onClick={(e) => {
            if (e.target === e.currentTarget) setShowLogin(false);
          }}
        >
          <section
            ref={dialogRef}
            tabIndex={-1}
            className="login-dialog"
            role="dialog"
            aria-modal="true"
            aria-labelledby="login-title"
          >
            <button
              className="close-button"
              aria-label="Close sign in"
              onClick={() => setShowLogin(false)}
            >
              ×
            </button>
            <img src="/rendprop-mark.svg" alt="Rendprop" />
            <p className="eyebrow">ONE ACCOUNT. YOUR CONTENT.</p>
            <h2 id="login-title">
              Your phone’s work.
              <br />A bigger canvas.
            </h2>
            <p>
              Sign in with the same Apple account connected in the Rendprop app.
              Your existing workspace permissions and plan carry over.
            </p>
            <button
              className="apple-button"
              disabled={authBusy || !services}
              onClick={() => void connect()}
            >
              {authBusy ? "Opening Apple…" : "Continue with Apple"}
            </button>
            {!services && (
              <p className="setup-note">
                Account sign-in is not configured on Studio. Local editing
                and the content planner work now.
              </p>
            )}
            <p className="small muted">
              If you have not connected an account in the iPhone app, link it
              there first to carry that workspace across devices. Signing in
              here cannot retrieve files that exist only on your phone.
            </p>
            <button
              className="text-button"
              onClick={() => {
                setShowLogin(false);
                navigate("editor");
              }}
            >
              Continue with local files <Icon name="arrow" size={16} />
            </button>
          </section>
        </div>
      )}
    </div>
  );
}

function EmptyConnect({ onConnect }: { onConnect: () => void }) {
  return (
    <div className="empty-connect">
      <span className="empty-icon">
        <Icon name="folder" size={30} />
      </span>
      <div>
        <h3>Your content belongs together.</h3>
        <p>
          Connect the account you use in the app to see its spaces here. Or
          start a video with files on this computer.
        </p>
      </div>
      <button onClick={onConnect}>
        Connect account
        <Icon name="arrow" size={17} />
      </button>
    </div>
  );
}
function SpaceList({
  spaces,
  select,
  selectedId,
}: {
  spaces: Listing[];
  select: (space: Listing) => void;
  selectedId?: string;
}) {
  return spaces.length === 0 ? (
    <div className="empty-inline">
      <h3>No spaces to show yet.</h3>
      <p>
        Create a property in Properties, or sign in to the same account on your
        iPhone. Uploaded photos and footage will appear in both places.
      </p>
    </div>
  ) : (
    <div className="space-list">
      {spaces.map((space) => (
        <button
          key={space.id}
          className={`space-row ${selectedId === space.id ? "selected" : ""}`}
          onClick={() => select(space)}
        >
          <span className="space-thumbnail">
            <Icon name="home" size={24} />
          </span>
          <span>
            <strong>
              {space.address || space.tagline || "Untitled space"}
            </strong>
            <small>
              {industryName(space.spaceType)} · {space.status}
            </small>
          </span>
          <Icon name="arrow" size={17} />
        </button>
      ))}
    </div>
  );
}
