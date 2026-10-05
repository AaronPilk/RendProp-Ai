# Native media export admission

Run on macOS with Xcode command-line tools:

```sh
python3 tools/audit/native-media-export-20261004/run.py
```

This compiles the unchanged production media-admission context, listing binding
resolver, compliance loader, original download caller, local photo/video caller,
CSV export caller and Photos permission/save helpers. Only transport, Photos,
view state and unrelated app types are offline doubles. Source and extracted-body
hashes, compiler/runtime logs and receipts are retained. The only filesystem
operations use synthetic source files and the operation's own temporary outputs.

The 102 assertions check valid original/photo/video/CSV exports; account,
session and workspace changes during a download or permission prompt; exact
listing/server/workspace binding changes; deletion and lost listing access;
cancellation; permission denial; unchanged original source bytes; removal of
owned returned downloads; and silent completion after Photos has already begun.
CSVs use a unique owned directory so another export with the same filename cannot
replace a share sheet's attachment.

Each fault must compile and then fail its named runtime assertion:

```sh
python3 tools/audit/native-media-export-20261004/run.py --inject-fault drop-permission-context
python3 tools/audit/native-media-export-20261004/run.py --inject-fault drop-listing-binding
python3 tools/audit/native-media-export-20261004/run.py --inject-fault drop-csv-context
python3 tools/audit/native-media-export-20261004/run.py --inject-fault drop-completion-context
```

Passing these offline checks does not certify real Files/Photos delivery or
physical camera behavior. A Photos transaction admitted before a context change
can finish in iOS; the caller then suppresses stale success, and later operations
are refused. This harness does not claim that an already begun OS write can be
cancelled.
