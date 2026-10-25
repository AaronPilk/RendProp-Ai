// PersistentStore moved into RendpropApp.swift.
//
// A brand-new .swift file only joins the build if xcodegen re-adds it to the
// target; a stale generated project silently drops it, which caused a
// "Cannot find 'PersistentStore' in scope" build failure. Keeping the type in
// RendpropApp.swift (always compiled) removes that failure mode. This file is
// intentionally left empty so it can't define the type twice if the target ever
// re-includes it.
