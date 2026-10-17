# Owner-bound Apple authorization code recovery

```sh
python3 tools/audit/apple-code-session-20261004/run.py
```

The 27 runtime assertions compile actual AuthStore sign-in, identity, code
envelope, submission and retry methods. Transport, credential persistence,
adoption scheduling and preferences are inert doubles. Nothing contacts Apple,
Supabase or the host Keychain. The production sign-in caller is source-bound to
the returned immutable identity and guards its name/completion update.

The tests reproduce account changes during token acquisition, held responses
across A/B sessions, a newer code from the same account, retrying B without
dispatching A's code, HTTP 200 without stored acknowledgement, expired bound
records, one persisted retry, malformed/unreadable/unwritable storage,
cancellation, wrong bearer subject and a sign-in replaced during adoption.
The legacy unscoped record stays preserved and is never rebound to an account.

Four independently compiled controls must fail their intended runtime check:

```sh
python3 tools/audit/apple-code-session-20261004/run.py --inject-fault drop-dispatch-fences
python3 tools/audit/apple-code-session-20261004/run.py --inject-fault drop-receipt-fences
python3 tools/audit/apple-code-session-20261004/run.py --inject-fault legacy-rebind
python3 tools/audit/apple-code-session-20261004/run.py --inject-fault drop-exchange-fence
```

Source/extracted-body hashes, compiler logs and runtime receipts remain in the
printed evidence directory. These tests establish software association and
recovery behavior; they do not establish real Apple exchange/revocation success
or actual Keychain durability.
