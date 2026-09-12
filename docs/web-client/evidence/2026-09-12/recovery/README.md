# Recovery iteration evidence

Runtime source: `d87e60c8abea65f2b2b54731e095e8217ac82dea`.
Deployment: `1ad1d0ab-b1a1-49ba-a9e1-4ccbeead04a1` on the dedicated Studio hostname.

- `deployment.json`: source/version/frozen-dist binding and explicit limits.
- `editor-browser.json`, `workspace-browser.json`: local built-byte checks.
- `connected-browser.json`: separately compiled real App/services, offline injected identity/fetch, NOT live OAuth.
- `connected-negative-control.json`: the intentionally broken source must fail; its wrapper checks the specific browser assertion.
- `deployed-assets.json`: actual HTTPS bytes/headers/SPA route, with known managed-robots exception stated.
- `deployed-editor-browser.json`: actual HTTPS app, 18 grouped checks and seven decoded synthetic video downloads.
- `deployed-workspace-browser.json`: actual HTTPS app, 17 grouped checks including real JSON/ICS downloads, merge/replace/cancel, quota failures and responsive navigation.

The earlier release's receipts remain in the parent directory unchanged. Paths to raw
screenshots and synthetic media are temporary OS artifacts, not durable release storage.
Neither the served Studio nor any fixture automatically posts content or changes accounts.
