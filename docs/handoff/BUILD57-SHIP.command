#!/bin/zsh
set -e
cd "$HOME/Rendprop AI/build57"

echo ""
echo "== 1/6  Branch state"
git status --short
git log --oneline -3
echo "Expected head: Build 57 commits on claude/build57-fixes-20261010"

echo ""
echo "== 2/6  Pushing branch claude/build57-fixes-20261010 to GitHub"
git push -u origin claude/build57-fixes-20261010

echo ""
echo "== 3/6  Mac-only native harnesses (need Xcode; about 10 minutes)"
node --test tests/phase1/*.test.mjs
python3 apps/ios/tests/run-push-account-isolation.py --out "$TMPDIR/rendprop-57-push-iso"
python3 tools/audit/required-account-onboarding-20261008/run.py --output-dir "$TMPDIR/rendprop-57-onboarding"
python3 tools/audit/listing-facts-review-20261004/run.py --output-dir "$TMPDIR/rendprop-57-facts"
python3 apps/ios/tests/run-native-ux-audit.py --evidence-dir "$TMPDIR/rendprop-57-ux"
python3 -m unittest discover -s tools/asc -t tools/asc

echo ""
echo "== 4/6  Website (rendprop.com): tests, then deploy"
cd services/edge/tour-host
npm ci
npm run predeploy
npx wrangler deploy
cd ../../..

echo ""
echo "== 5/6  Studio: tests and build, then deploy"
cd apps/studio
npm ci
npm run verify
npx wrangler deploy
cd ../..

echo ""
echo "== 6/6  Checking what is live"
sleep 5
if curl -fsS "https://rendprop.com/features?b57" | grep -qi "coming soon"; then echo "OK  /features marks measurements and floor plans Coming soon"; else echo "CHECK  /features does not show the Coming soon block yet"; fi
if curl -fsS "https://rendprop.com/support?b57" | grep -q "do not open yet"; then echo "OK  /support says the Coming soon tools do not open yet"; else echo "CHECK  /support is not updated yet"; fi
if curl -fsS "https://rendprop.com/pricing?b57" | grep -q "Floor plan"; then echo "CHECK  /pricing still mentions floor plans"; else echo "OK  /pricing no longer sells floor plans"; fi
echo "Cache check (purge /terms and /support in Cloudflare if these say HIT):"
curl -sI https://rendprop.com/terms | grep -i "cf-cache-status" || echo "cf-cache-status: not present"
curl -sI https://rendprop.com/support | grep -i "cf-cache-status" || echo "cf-cache-status: not present"

echo ""
echo "Done. Branch pushed; website and Studio deployed; backend was already deployed by Claude."
echo "Next:"
echo "  1. GitHub > Actions > CI > Run workflow on claude/build57-fixes-20261010; all 12 jobs must be green."
echo "  2. Archive 1.0.4 (57) from this branch once CI is green:"
echo "       bash tools/asc/bridge-600-archive-upload.sh --no-upload"
echo "       bash tools/asc/bridge-600-archive-upload.sh"
echo "  3. Re-capture App Store screenshot frame 1 from build 57 (the old capture shows a live Floor plan tool)."
echo "  4. No App Store submission until the independent GO."
read -k1 "?Press any key to close this window."
