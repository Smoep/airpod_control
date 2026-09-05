# Lessons Learned

Notes from working on Always On head-gesture recognition. Only confirmed items.

## 1. Tuning values that worked
- Calm Motion (`motionThreshold`): slider range 0.001–0.020. Tested 0.001–0.010.
  - 0.001 is very strict (slow to rearm/finish). ~0.004–0.008 is the practical zone.
- Start Movement (`alwaysOnStartThreshold`): 0.115 in testing.
- Minimum Speed (`alwaysOnGestureSpeed`): 1.5 rad/s; cleanly ignored slow drift.
- Finish Delay (`alwaysOnFinishDelay`): 0.05.
- Return To Neutral (`alwaysOnReturnToNeutralRadius`): 0.20.
- Neutral Settle (`alwaysOnNeutralSettleDuration`): 0.30.
- Confidence threshold: 0.63. CAL 01 Right fired at ~0.94–0.99.

## 2. Things that caused problems
- Calm Motion first only affected finish timing, not reset/recenter, so it felt
  like "nothing changed". Fix: also gate reset/recenter calm checks on it.
- CAL 01 Right misses scored ~0.54–0.55 (below 0.63). Yaw was strong (~0.9 axis
  score); the penalty came from extra pitch/roll coupling at the end of the move.
- Verbose logging left ON floods `/tmp/airpod_control.log` and raises CPU.
  Keep `debugMode=true`, `verboseDebugMode=false` for normal testing.
- Recorded calibration samples are not enough to judge a matcher change. Trackpad
  Control measured excellent leave-one-out accuracy while real use still failed.
  Preserve and replay live attempts before tuning recognition logic.
- Always-on diagnostics need explicit disk bounds just like in-memory sensor paths.
  The debug log now keeps about 4 MiB when it crosses 5 MiB; the persistent live
  gesture corpus keeps about 16 MiB when it crosses 20 MiB.
- Stale git worktree blocked branch delete; had to remove the
  `.git/worktrees/<name>` admin entry, then `worktree prune`, then `branch -D`.

## 3. Build/run steps that work
- Unit tests:
  `xcodebuild -quiet test -project airpod_control.xcodeproj -scheme airpod_control -destination 'platform=macOS' -derivedDataPath .build -only-testing:airpod_controlTests`
- Build + deploy:
  `xcodebuild -quiet -project airpod_control.xcodeproj -scheme airpod_control -destination 'platform=macOS' -derivedDataPath .build build`
  then `ditto .build/Build/Products/Debug/airpod_control.app "/Applications/AirPods Control.app"`,
  `pkill -x airpod_control || true`, `open -n "/Applications/AirPods Control.app"`.
- Verify deploy: compare `md5 -q` of built vs installed binary (must match).
- Restore logging via plist: `airpod_control.debugMode=true`,
  `airpod_control.verboseDebugMode=false` in `~/Library/Preferences/com.jos.airpod-control.plist`.

## 4. Useful log messages and what they mean
- `STATE always_on neutral -> moving`: a capture started (distance + speed passed).
- `STATE always_on start_ignored reason=slow`: above distance but below Minimum Speed.
- `STATE always_on slow_drift -> neutral`: slow drift recentered the baseline.
- `STATE always_on neutral_refreshed`: baseline refreshed; shows `motion` vs `calmMotion`.
- `BAIL finalize_discrete reason=idle_delay`: still waiting out Finish Delay.
- `DECISION discrete_eval ... scores=[...]`: ranked candidates for the capture.
- `DECISION discrete_match result=fire`: gesture passed threshold + margin, action ran.
- `DECISION discrete_match result=reject reason=below_threshold`: top candidate scored under confidence.
- `GESTURE_REPLAY {…}`: schema-versioned replay payload with the activation layer,
  outcome, matched name, ranked scores, and a compact 6-axis path. An equivalent
  full-resolution record is appended across launches to
  `~/Library/Application Support/AirpodControl/gesture-attempts.jsonl` while debug
  logging is enabled (the normal log remains compact).
- `STATE always_on moving -> reset_wait` / `reset_wait -> neutral`: post-gesture
  return/recenter; `motion` vs `calmMotion` shows how still the head is.

## 5. Diagnosis workflow carried over from Trackpad Control
- Measure before theorizing: start with the decision log and replay corpus, and call
  an explanation a candidate hypothesis until a live attempt confirms it.
- Treat real input as ground truth. Do not reshape how a user moves to suit the
  recognizer; adapt and validate the recognizer against recent live attempts.
- Keep marker names stable because logs are a debugging interface. Add fields or a
  new schema version instead of silently changing existing meanings.
- A successful build alone does not prove deployment. Compare built and installed
  binary hashes, confirm a new PID, then verify the launch marker in the runtime log.
