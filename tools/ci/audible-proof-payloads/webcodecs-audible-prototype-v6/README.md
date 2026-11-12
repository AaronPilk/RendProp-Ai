# Disposable v6 proof payload

`prepare-audible-copy.py` verifies the 19 relevant shipping 1c input pins, pinned external Mediabunny 1.65.2 package, and every payload hash before copying seven files into an external disposable checkout. The caller must separately bind the full 3340-member source archive. The preparer refuses the active release checkout and existing output paths. Preparation does not launch a browser, encode media, or run provider jobs.

Run the preparer only against a fresh Git archive of shipping commit `1c561d7b91d9b75bd7ba29aa081fcba959089fee`. The browser harness retains the v5 strict output, PCM, pitch, transition, refusal, cleanup, and no-download oracles. It adds source-bound observation of the single early stream sink; v6 has not been run in a browser. `silent-output-bootstrap.test.ts` is a closed fake-graph test. The `disposable/` directory contains an external, non-running full Studio TypeScript check with the v6 source overlaid.

The current exact `payload-hashes.json` and independent review govern any future run. The full disposable Studio and fixture TypeScript check uses the project's `skipLibCheck: true`; forcing it off fails third-party declarations in both the shipping and disposable projects. A successful static check is not media or device verification.
