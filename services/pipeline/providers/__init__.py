"""Provider adapters for the Rendprop AI-enhancement pipeline.

Each module is a thin, pure API client for one provider and exposes:
  • a clean function (restage / declutter / hero_clip / judge)
  • KNOWN unit-cost constants (sourced from providers/costs.py)

Routing, budget enforcement, retries/QC, and cost-ledger writes live one layer
up in router.py — the adapters just call the API and return bytes / a result.
"""
