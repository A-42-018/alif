# GitDrip — Android Control Plane + Termux Execution Plane
(Replanned for free-tier-sized phases)

## STATUS
- Current phase: **P15b IDE half — DONE (Gradle build green on user's Mac)**; **device half PENDING**. Engine 0.17.0 (P7.5 pr-flow), app 0.16.1 (versionCode 9). User ran `gradle wrapper --gradle-version 8.7` in `android/` (wrapper files are local, not in this zip; run it again after unzipping) + `local.properties` (`sdk.dir=...`, not committed). `./gradlew test` = BUILD SUCCESSFUL: compileDebug/ReleaseKotlin, compileDebug/ReleaseUnitTestKotlin and unit tests all pass, so every android.*-dependent Kotlin file (Notify, SettingsScreen, A11y, Secure/Vault, MainViewModel, UI, Room v5 schema/KSP) now compiles. Only warnings: `Scheduler.kt:49` unused param `catchUp`, `Scheduler.kt:63` shadowed `id`, `NotifyBackupTest.kt:43` deprecated `createTempDir`. User's SDK folder has a nested `sdk/android app/` layout (harmless "inconsistent location" notices; fix by pointing `sdk.dir` at the real root or reinstalling via SDK Manager). Still unverified (needs device/emulator): Room migrations v1->v5 at runtime, notifications/permission prompt, TalkBack, Keystore, alarms/reboot, Termux RUN_COMMAND, pr-flow against real GitHub.
- P16b done: (1) Engine `lib/bridge.sh`: `bridge <req> backup [--full] | restore <name> [--force] | cfg-export | cfg-import <name>` (files only in `<ex>/backups/`, names must match `gitdrip-(backup|config)-YYYYMMDD-HHMMSS.(tar.gz|json)`, regular non-symlink files only, newest 10 backups kept, result `{state OK|ERROR, reason}` = last engine line, redacted; backup/restore work without jq, cfg-import needs jq). (2) Android notifications: `data/NoteLogic.kt` (pure `noteFor`: failures always, successes only if enabled, retries/skips silent, same state twice = once, runs finished >30 min ago never notify so the first history sync cannot flood, text redacted ≤120 chars), `data/Notify.kt` (channels `failures` HIGH / `results` LOW, `POST_NOTIFICATIONS` runtime permission on API 33+, silent no-op when denied, tap opens app, lock-screen visibility private), hooks in `MainViewModel.applyResult`, `mergeHistory` (max 3 per sync), `Scheduler.fire` failures. (3) Accessibility: `A11y.kt` (`LabeledSwitch` = whole row toggleable ≥48dp with Role.Switch, `asHeading`), headings on all top bars, Stat cards merged into one "label: value" node, clickable rows have role + click label, schedule switch labelled, bare Switch+Text pairs replaced; no fixed sp/heights exist so system font scale applies. (4) Backup UI: `SettingsScreen.kt` (notification permission + success toggle, Back up now, "include repo/source" switch, Export config, saved-files list with Restore/Apply + confirm dialog + overwrite switch), `data/Backup.kt` (pure: name rule, list newest first, ignores dirs/symlinks/foreign names), Dashboard "Settings & backup" button, route `settings`. Manifest + `tests/test_p14.sh` audit now allow exactly: MANAGE_EXTERNAL_STORAGE, POST_NOTIFICATIONS, RECEIVE_BOOT_COMPLETED, SCHEDULE_EXACT_ALARM, RUN_COMMAND.
- P16b tests: `bash tests/test_p16.sh` = 33/33 pass (jq import checks skipped: no jq); P14 25/25, P1 9/9, P10 part 1 8/8, P13 transport 18/18 re-run OK. `NotifyBackupTest.kt` (9 JVM tests) written and wired into `tests/kt_run.sh`, NOT run (no kotlinc in sandbox). Kotlin/Compose/Gradle, notification delivery, permission prompt, TalkBack pass: unverified.
- P16b known gaps: Room DB is not in the backup (app projects must be re-created with the same names after a restore, then Sync rebuilds history); restore updates Termux state only, never the app's batch editor; backups sit unencrypted in shared storage (no token inside, but repo/source with `--full`); `chmod 600` on shared storage is a no-op on most devices; no notification actions (Retry button); no per-project notification mute; success notification uses commit hash only; contrast/TalkBack not audited on device.
- Next step: **P15b device half**: Android Studio -> Run on emulator/phone (minSdk 26, target 34). Install Termux (F-Droid/GitHub), `pkg install openssl-tool jq git curl`, copy `gitdrip/` (0.17.0), paste the app's setup command, Setup -> "Send token to Termux" -> "Check token", then the P15 matrix (fresh install, Termux missing, invalid token, offline, reboot, duplicate run, simultaneous tasks, failed push, permission error, timezone change) + Settings -> Back up now -> Restore + failure notification. Report crashes/logcat. Also try `gitdrip pr-flow <p> <batch> --issue --merge` once on a real repo. Optional after: clean the 3 warnings, bridge/app "Run as PR" (P7.6), `gitdrip watch` (P7.7), P17 OAuth.
- P15b device-debug (2026-10-04): (1) `GitHubUi.kt` `SecureWindow(enabled: Boolean)`: FLAG_SECURE only while the token field is non-empty (`SecureWindow(enabled = token.isNotEmpty())`, `DisposableEffect(w, enabled)`); rest of Setup screen can be screenshotted; PasswordVisualTransformation unchanged. Not compiled/run. (2) Open on device: app -> Termux RUN_COMMAND never reaches Termux ("No answer", results/ gets no new file; the "update engine to 0.14.0" text is only the generic no-result message, not a version check); `auth set` rejects a fine-grained token (diagnose with length/prefix check at the hidden prompt, re-enter via grep-extract).
- Current phase: P15b device half, in progress (engine 0.17.0 verified in Termux incl. `bridge t1 doctor`; app->Termux link still failing).
- Next roadmap: find why RUN_COMMAND is not delivered (checklist: Termux battery Unrestricted / Samsung sleeping apps, Appear on top, allow-external-apps, `ls -l $PREFIX/bin/gitdrip`, `adb logcat` for RunCommandService, app All-files access so baseDir = /storage/emulated/0/GitDrip) -> re-enter token -> P15 matrix -> pr-flow on a real repo -> P7.6/P7.7/P17.
- Last updated: 2026-10-04
- P1 notes: runtime data in `$GITDRIP_HOME` (default `~/.gitdrip`: config.json, logs/, projects/, tasks/, locks/); CLI symlinked to `$PREFIX/bin`; `lib/common.sh`, `lib/logger.sh` (token redaction, rotation); `bash tests/test_p1.sh` = 10 checks pass
- P2 notes: `gitdrip import <dir> [--name N] [--max N] [--force]` copies files to `projects/<name>/source/` (skips .git, node_modules; .env/*.pem/*.key/id_rsa*/keystores NOT copied, listed in `excluded.txt` + manifest `excluded`), writes `manifest.json` (path,size,sha256) then `batches.json`. Batches = per-directory module, ≤ `batch_max_files` (default 5), split into "(part i/n)", conventional msg (docs/test/feat), status PENDING. `gitdrip batches <p>` shows "commits available". Regenerate/re-import refused once any batch ≠ PENDING. Needs jq. `bash tests/test_p2.sh` = 17 checks pass. Files: lib/manifest.sh, lib/batch.sh.
- P3 notes: repo at `projects/<p>/repo`. `gitdrip repo-init <p> [--remote URL] [--branch B] [--user N] [--email E]` (remote URL with creds rejected; auth = P5). `gitdrip run-batch <p> <id> [--dry] [--no-push]`: compares batch files source vs repo → none changed = STOP (exit 3, batch `NOCHANGE`, no empty commit); copies only changed batch files, `git add -- <files>` (never -A), refuses if unrelated files already staged, commits with batch message (real author date, no backdating), pushes `HEAD:refs/heads/<branch>` (never force). Batch status flow: `PENDING → COMMITTED` (local commit, `commit` hash stored) `→ SUCCESS`; push failure leaves COMMITTED and rerun only pushes (no duplicate commit); SUCCESS/NOCHANGE reruns are no-ops. `git-status <p>`. Preflight (`git_preflight`): identity missing = block; warns if email not noreply / not in config `verified_emails` (comma list), branch ≠ `default_branch`, no origin. Fork detection deferred to P13 (needs API). Files: lib/git.sh (139 lines), tests/test_p3.sh = 21 checks pass (P1 10, P2 17). Version 0.3.0.
- P4 notes: `lib/runner.sh` (153 lines). `gitdrip run <p> [batch-id]` = task-create + task-run (default batch = first COMMITTED, else first PENDING; none → "no pending batches", exit 0). `task-create <p> [id]` prints task_id (reuses an open PENDING/RUNNING task for same project+batch). `task-run <task_id>` (Android passes only task_id), `tasks [p]`, `task-show <id>`. Task JSON `tasks/<id>.json`: id, project, batch_id, key=`project:batch`, state PENDING→RUNNING→SUCCESS|FAILED|SKIPPED, attempt, created/started/finished/updated_at, reason, output (last 10 redacted lines), exit_code, commit, files_changed. SUCCESS/SKIPPED tasks rerun = no-op; FAILED task can be rerun (attempt++, COMMITTED batch only pushes); batch already SUCCESS/NOCHANGE → task SKIPPED; git exit 3 → SKIPPED "no changes". Lock `locks/<p>.lock` = "pid epoch", created atomically via `ln`; stale = dead pid / garbage / older than config `lock_stale_minutes` (30) → taken over; live lock → exit 4, task stays PENDING. RUNNING task with no live owner is recovered. Exit codes: 0 ok/already done, 1 failed, 3 skipped(no change), 4 locked, 5 (internal: no batches). Runner refuses when config `dry_run=true`. Tests: `bash tests/test_p4.sh` = 26 checks (includes P1–P3 regression; tests set GIT_CONFIG_GLOBAL=/dev/null so host git identity can't leak). Version 0.4.0. Known limit: stale-lock takeover has a tiny race window (no flock in Termux by default); push-vs-lock only per project.
- P5 notes: `lib/auth.sh`, `lib/scan.sh` (new); git.sh/runner.sh/logger.sh/bin/gitdrip extended. Version 0.5.0. `GITDRIP_HOME` now exported.
  - Auth: `echo TOKEN | gitdrip auth set --user NAME` (stdin/hidden prompt only, never argv; format-checked ghp_/gho_/ghu_/ghs_/ghr_/github_pat_) → `$GITDRIP_HOME/credentials` (`user=`/`token=`, chmod 600, auto-repaired if loosened). `auth status` (masked), `auth clear`. Push uses `git -c credential.helper= -c credential.helper='!gitdrip credential-helper'` (answers `get` only for https://github.com; store/erase no-ops), `GIT_TERMINAL_PROMPT=0`. Token never in URL/argv/env/logs; repo-init and preflight BLOCK remotes with creds in URL.
  - Scanner: `gitdrip scan <project|dir>` (exit 1 on hits; prints `file:line: rule` only, never the secret). Rules: github_token, aws_access_key, private_key, slack_token, google_api_key, stripe_live_key, generic_secret (password/secret/api_key=“16+ chars”), secret filenames (.env, *.pem, *.key, id_rsa*, …; `.env.example` ok). Inline `gitdrip:allow` suppresses a line. Wired in `git_run_batch` on changed source files BEFORE copy/stage (also in `--dry`): hit → return 6, nothing copied, batch stays PENDING, task FAILED reason `secret_blocked`, `error_class=secret`.
  - Log redaction (`_log_redact`) extended: bearer/Authorization, `password=/token=`, slack/google/stripe, private-key header, plus the stored token masked literally.
  - Preflight (`_elig_checks`, `gitdrip preflight <p>`): BLOCK = identity missing / creds in remote URL; WARN = non-noreply/unverified email, noreply user ≠ authenticated user, non-default branch, no origin, remote not github.com, https github remote without credentials, daily cap (`max_commits_per_day`) reached (warn only; enforcement → P7). Fork check still P13.
  - `.gitignore`: `repo-init` merges defaults into `repo/.gitignore` (idempotent, keeps user lines). It stays untracked locally unless a batch carries the project's own .gitignore (which then overwrites it); scanner is the real guard.
  - Push-error classifier `classify_push_error` → auth|conflict|transient|fatal|unknown; failures log `push failed [class]`; runner stores `error_class` on FAILED tasks (P6 input).
  - Tests: `bash tests/test_p5.sh` = 38 checks (includes P1–P4 regression, 26).
- P6 notes: `lib/retry.sh` (new, ~80 lines); runner.sh/git.sh/auth.sh/bin/gitdrip extended. Version 0.6.0.
  - Only `error_class=transient` is retried (auth/fatal/conflict/secret/unknown stay FAILED). Backoff = config `retry_backoff_minutes` (default "0,2,5,15": first attempt now, retries at +2/+5/+15 min); after the last → FAILED reason "retries exhausted: …".
  - New task state `PENDING_RETRY` with `retries`, `next_retry_at` (ISO), `next_retry_epoch`, `error_class=transient`. Exit code 7 = retry scheduled / not due. `task-run <id>` before its time → "not due", exit 7; `task-run <id> --now` ignores the timer; re-running a FAILED task resets `retries` to 0 (user "Retry" button). task-create reuses PENDING_RETRY tasks. Lock is released between retries (process exits).
  - `gitdrip retry-due [--list]` runs all due PENDING_RETRY tasks (P7 cron should call it alongside the scheduled run). `gitdrip net-check <p>` (exit 1 offline).
  - Offline precheck (`net_online`) runs before RUNNING: curl -sI -m 5 to remote host (ssh/scp remotes → github.com; local path/no remote → online). Offline = nothing attempted, attempt not incremented, retry not consumed, next check +`retry_backoff[1]` min. Env `GITDRIP_NET=online|offline` overrides the probe (tests/airplane-mode simulation).
  - Verify before re-push (`retry_verify_commit`, COMMITTED resume path): commit not in `HEAD` ancestry → log `push failed [fatal]`, no push; `git ls-remote origin refs/heads/<br>` already contains commit → batch marked SUCCESS without pushing ("already on remote"); remote unreachable → push decides. 
  - Classifier extended with "failed to connect / couldn't connect / no route to host / name or service not known".
  - Tests: `bash tests/test_p6.sh` = 23 checks (includes P1–P5 regression, 38). Known limits: offline waits are unbounded (no cap on how long a task sits in PENDING_RETRY); `date -d` needs GNU date (Termux ok); `conflict` (non-fast-forward) is not auto-resolved — P7+ may add a `git pull --rebase` option.
- P7 notes: `lib/schedule.sh` (new, ~190 lines); bin/gitdrip, config, common.sh extended. Version 0.7.0.
  - `gitdrip schedule add "HH:MM" <p> [--policy skip|run-now|next-slot]` → id; `list`, `remove <id>`, `enable|disable <id>`, `install|uninstall`, `next`, `fire <id>`, `tick`. State `$GITDRIP_HOME/schedules.json` ({id,time,project,policy,enabled,last_fire_day,carry}).
  - crond: managed block `# >>> gitdrip >>>`…`# <<< gitdrip <<<` in the user crontab (foreign lines kept, idempotent): one `MM HH * * * gitdrip schedule fire <id>` per enabled slot (system-local time) + `*/5 * * * * gitdrip schedule tick`. add/remove/enable/disable re-install automatically. Start crond in Termux: `sv-enable crond` (termux-services) or `crond`.
  - `fire`: marks slot fired today, runs 1+carry batches via `task_create`/`task_run` (picker = `_next_batch`), stops at first non-zero; then `retry-due`. Exit 8 = daily cap reached. Cap = config `max_commits_per_day` across ALL projects (SUCCESS tasks with a commit, local day).
  - `tick`: runs `retry-due`, then missed-slot policy: slot is missed if now > slot + `missed_grace_minutes` (default 10) and not fired today. skip = drop; run-now = fire now; next-slot = carry to the project's next unfired slot today (that slot runs 1+carry batches, still capped), none left → dropped.
  - Env for tests: `GITDRIP_NOW=<epoch>` fixes clock, `GITDRIP_CRONTAB_CMD` replaces `crontab`. New config keys: `missed_grace_minutes`, `retry_backoff_minutes`.
  - Tests: `bash tests/test_p7.sh` = 21 checks (includes P1–P6 regression, 23). Known limits: cron uses device-local time (config `timezone` not applied); Android doze may pause Termux crond (P11 AlarmManager is the fix); `preflight` cap warning still per-project UTC while scheduler cap is global local-day; no per-weekday schedules yet (daily only).
- P8 notes: `android/` (Gradle Kotlin DSL, no wrapper — open in Android Studio or run `gradle wrapper`). AGP 8.5.2, Kotlin 1.9.24, Compose BOM 2024.06.00 (compiler 1.5.14), Room 2.6.1 via KSP, Navigation 2.7.7; minSdk 26, target 34; package `com.gitdrip.app`; no INTERNET permission yet; `allowBackup=false`.
  - Files: `data/Db.kt` (entities Project/Batch/Schedule/Execution with FK cascade, ProjectDao, StatsDao, AppDb v1, `validateProject`), `GitDripApp.kt` (lazy db), `MainViewModel.kt` (flows, create/delete), `MainActivity.kt` (NavHost: dashboard, projects, new, project/{id} with Files|Batches|Schedule|History placeholder tabs; delete w/ confirm), `test/ValidationTest.kt` (6 JVM tests).
  - Rules mirrored from engine: project name = slug `[a-z0-9][a-z0-9._-]{0,39}` (same charset as `slugify`), repo must be `https://github.com/owner/repo` (no creds), unique name.
  - Room mirrors Termux state (executions.taskId = tasks/<id>.json id); deleting a project removes app rows only, never Termux files. Schema `exportSchema=false`, v1, no migrations yet.
  - NOT verified: sandbox cannot reach Google Maven, so no Gradle build, no unit-test run, no on-device run. Engine regression (`tests/test_p7.sh`) also not re-run (jq missing in sandbox; engine files untouched in P8).
  - Known gaps: no project edit/pause UI; dashboard counts only; Project name not yet linked to a Termux import (P9/P10); setup screen + "Private contributions" reminder deferred to P10.
- P9 notes: version 0.9.0 (versionCode 2). Room v2 with `MIGRATION_1_2` (adds `files`); no destructive fallback.
  - New: `data/Batching.kt` (pure Kotlin: `isSecretPath`, `isSkippedPath`, `sanitizePath`, `suggestBatches`, `moved`), `data/Importer.kt` (SAF folder / multi-file / ZIP → `<GitDrip dir>/<project>/source`, SHA-256 per file), `ProjectTabs.kt` (FilesTab, BatchesTab); extended `Db.kt` (FileEntity, BatchDao), `MainViewModel.kt`, `MainActivity.kt` (Files + Batches tabs live), manifest (`MANAGE_EXTERNAL_STORAGE`), `test/BatchingTest.kt` (8 JVM tests).
  - Rules mirrored from engine: skip `.git`/`node_modules`; `.env*` (not `.env.example`), `id_rsa*`, `id_ed25519*`, `*.pem|key|jks|keystore|p12|pfx` NEVER copied (reported in status); batches = per-directory module, ≤5 files, "(part i/n)", messages `docs|test|feat: add <dir> module` / `project root files`. Caps: 3000 files, 300 MB total (zip-bomb guard); zip-slip/absolute/`..` paths dropped + canonical-path check.
  - Storage: target `/storage/emulated/0/GitDrip/<project>/source` when All-files access granted (Termux reads it as `~/storage/shared/GitDrip`); otherwise falls back to app external dir (Termux CANNOT read it) and the Files tab shows a banner with a Settings button.
  - Batch editing (auto-suggest, add, rename, delete, move up/down, assign file→batch via tap) is refused once any batch ≠ PENDING (same rule as engine). Re-import wipes app batches + the source dir. Files not assigned to any batch simply aren't committed.
  - Room is the editing model only; engine `batches.json` is NOT yet written from it. P10 must (a) run `gitdrip import <dir>` / write `batches.json` from Room (engine fields: id, name, message, files[], status) and (b) sync status back. Engine `batch_create` and app `suggestBatches` use the same wording but app files are the source of truth for assignment.
  - Verified: `Batching.kt` + `BatchingTest.kt` compiled with kotlinc 1.9.24 and 8/8 pass (JUnit shimmed; real JUnit unreachable in sandbox). NOT verified: Gradle build, Room schema/migration, SAF import on device, Compose UI. Engine tests not re-run (engine untouched).
  - Known gaps: no progress bar for large imports; ZIP password/nested zips unsupported; no per-file exclude toggle; unassigned-file warning only as a count; batch drag-reorder is up/down buttons.
- P10 notes: version 0.10.0 (versionCode 3). Room v3 with `MIGRATION_2_3` (adds `executions.requestId`). New config key (optional): `exchange_dir`; env `GITDRIP_EXCHANGE` (default `~/storage/shared/GitDrip` = Android `/storage/emulated/0/GitDrip`).
  - Protocol (app ⇄ engine, files only, no secrets): app writes `<ex>/<project>/source/` (P9) + `<ex>/<project>/plan.json` `{project, repo?, branch, batches:[{id=seq, message, files[]}]}`, then fires Termux `RUN_COMMAND` (`com.termux.app.RunCommandService`, background, path `/data/data/com.termux/files/usr/bin/gitdrip`) with `bridge <req> run <project> [batch-rank] --sync`. Engine writes `<ex>/results/<req>.json` (state RUNNING → SUCCESS|FAILED|SKIPPED|PENDING(locked, exit 4)|PENDING_RETRY|ERROR; fields req, action, project, state, reason, exit_code, output (redacted, last 10 lines), task_id, batch_id, commit, files_changed, attempt, next_retry_at, batches[{id,status,commit}]). App polls it every 1 s (5 min max). Request id regex `[A-Za-z0-9._-]{1,64}`, project = slug regex (no path escape).
  - Engine `lib/bridge.sh` (~170 lines): `gitdrip bridge <req> doctor | sync <p> | run <p> [batch-id] [--sync] | status <p>`. Sync = validate plan (no abs/`..` paths, no secret/excluded names, no file in two batches, repo must be https://github.com/o/r, no creds) → under project lock: re-import `source/` + manifest + write `batches.json` (engine id = rank of plan batch by plan id) + `repo-init` (remote/branch/user/email from plan). **Once any batch ≠ PENDING the plan is NOT re-applied** (so ids stay stable). Doctor works without jq and reports tools/storage_link/exchange_writable/auth. Never creates `~/storage/shared` itself.
  - Android: `data/TermuxBridge.kt` (installed/permission checks, `send`, plan/result/doctor JSON helpers, `SETUP_COMMAND`), `SetupScreen.kt` (checklist: Termux, RUN_COMMAND runtime permission, All-files access, copyable setup command, “Test connection” = doctor, Private-contributions reminder), VM `runBatch/reconcile/checkEngine`, Batches tab “Run next” + per-batch ▶, Dashboard “Termux setup” button, `ExecDao`, `BatchDao.setStatus`. Room batch status + executions mirror the result file; ERROR is stored as FAILED; batch edits are refused while a run is open. Open executions are reconciled from result files when a project opens.
  - Tests: `bash tests/test_p10.sh` = part 1 (8 checks: doctor, request-id/project validation, no tmp leftovers) PASSED in sandbox; part 2 (sync/run/secret/lock/regression, ~22 checks) needs jq and was NOT run (sandbox has no jq/kotlinc). `BridgeTest.kt` (7 JVM tests, needs `org.json:json` test dep, added) NOT run.
  - Known gaps: engine is not bundled in the APK (user copies `gitdrip/` to Download and pastes the setup command); GitHub token is still entered in Termux (Keystore handoff = P14); PENDING_RETRY / cron-run results are not pulled back until P12 sync; engine batch rank assumes batches with no files are skipped; one run at a time per app (not per project); `RUN_COMMAND` failures when `allow-external-apps` is unset only show as “no answer from Termux”; repo branch change after first repo-init is not applied.
- P11 notes: version 0.11.0 (versionCode 4). Room v4 with `MIGRATION_3_4` (schedules: `zone` '' = device zone, `days` bitmask bit0=Mon..bit6=Sun default 127, `lastFireDay`; old `next-slot` → `skip`). Engine untouched.
  - New: `data/ScheduleMath.kt` (pure java.time: `validTime/validZone/zoneOf/nextFire/isMissed/dayKey/daysLabel`, `DAILY_CAP=3`, grace 10 min), `data/Scheduler.kt` (AlarmManager: `arm/cancel/armAll/fire/restore`), `ScheduleReceivers.kt` (`AlarmReceiver`, `BootReceiver`), `ScheduleTab.kt` (list, add/edit dialog, enable switch, delete, exact-alarm + battery-optimization prompts), `SchedDao`, VM `saveSchedule/setEnabled/deleteSchedule`, `test/ScheduleMathTest.kt` (8 JVM tests). Manifest: `SCHEDULE_EXACT_ALARM`, `RECEIVE_BOOT_COMPLETED`, receivers (boot, package replaced, TIME_SET, TIMEZONE_CHANGED).
  - Flow: one exact alarm per enabled schedule (`setExactAndAllowWhileIdle`; inexact `setAndAllowWhileIdle` if exact not granted). Fire → skip if already fired today / weekday off / project paused / daily cap (3, app-wide, non-FAILED/SKIPPED executions today) / run open → else write `plan.json`, insert PENDING execution, send ONE `bridge <req> run <p> --sync` to Termux, then ALWAYS re-arm next occurrence. Skips/failures are logged as SKIPPED/FAILED executions with a reason.
  - Reboot/time/timezone/app-update → `restore`: re-arm all; policy `run-now` fires slots missed today (>10 min late, not fired today); `skip` just re-arms. Zone "" follows the device zone (re-armed on TIMEZONE_CHANGED).
  - Policies in app: `skip | run-now` only. `next-slot` + carry stay Termux-cron-only (`gitdrip schedule`). App alarms and Termux crond are independent: do NOT enable both for the same project (double runs; project lock + "already fired" guard limit but don't remove this).
  - NOT verified: Gradle build, Room v4 migration, alarm firing after swipe-away / reboot, Termux RUN_COMMAND from a background alarm, ScheduleMathTest (no kotlinc/Gradle in sandbox). 
  - Known gaps: fire is fire-and-forget (no polling; result is picked up by `reconcile` when the project opens, full sync = P12); `fire` duplicates the plan/send steps of `MainViewModel.runInner` (refactor into a shared runner in P12); daily cap is app-side constant, not read from engine config; no notification on failure (P16); SCHEDULE_EXACT_ALARM can be revoked by the user (UI banner only on this tab); deleting a project cancels alarms via VM only.
- P12 notes: version 0.12.0 (versionCode 5; engine `GITDRIP_VERSION=0.12.0`). Room v5 with `MIGRATION_4_5` (executions: `output`, `filesChanged`, `attempt`, `errorClass`, `nextRetryAt`).
  - Engine: `gitdrip bridge <req> history <p>` (lib/bridge.sh `bridge_history`) writes `results/<req>.json` = normal result + `tasks[]` (last 30 tasks of that project, newest first: id, batch_id, state, commit, files_changed, attempt, reason, output, error_class, next_retry_at, created/started/finished_at) + `batches[]` states. Needs jq. Invalid project → ERROR result. Tests: 5 new checks in `tests/test_p10.sh` (total 33).
  - Android: `data/History.kt` (pure: `HistoryTask`, `isTerminal`, `redact`, `commitUrl`, `isoMs`, `durationLabel`, `commitStats`), `HistoryUi.kt` (`HistoryTab`, `RunRow`, `RunDetailScreen`, `fmtTime`), `TermuxBridge.kt` (`parseHistory`, `pruneResults`, `BridgeResult` + output/attempt/nextRetryAt/batchId), `Db.kt` (new DAO queries), `MainViewModel.kt` (P12 section: `sync`, `mergeHistory`, `stats`, `nextRun`, `latestRuns`, `retrying`), `MainActivity.kt` (Dashboard rewrite, `run/{id}` route, History tab live).
  - Sync: History tab auto-syncs on open + “Sync from Termux” button; Dashboard “Sync all”. Flow per project: reconcile open runs from result files → send `bridge <req> history <p>` → poll ≤20 s → merge by `taskId` (tasks run by Termux cron or finished after a retry are inserted/updated; an app-started run with no task id yet is adopted if started within ±2 min of the task) → batch statuses refreshed. History result file is deleted after reading; result files older than 30 days are pruned.
  - History: list per project (latest 100), tap → run detail: state, project, batch, start/finish/duration, commit (+ “Open commit on GitHub” for github.com repos), files changed, attempt, next retry (UTC), error class, reason, task id, redacted output (monospace, selectable). “Retry this batch” (FAILED) / “Retry now” (PENDING_RETRY) re-runs the batch via the normal bridge run if the batch is not SUCCESS.
  - Dashboard: projects, active schedules, commits today / this week (Mon–today) / streak (consecutive days with ≥1 pushed commit, ending today or yesterday), failed today, runs waiting for retry, next run (earliest alarm of unpaused projects), latest 8 runs. “Commit” = execution SUCCESS with a commit hash; device-local days.
  - Redaction: engine output is already redacted; app applies `redact()` again (tokens, Authorization, password=/token=, creds in URLs, private-key header) before storing and displaying.
  - NOT verified: Gradle build, Room v4→v5 migration, Compose screens, Termux `history` over RUN_COMMAND on device (engine action itself is tested). 
  - Known gaps: “eligible” = pushed commits only — the engine’s email/branch eligibility warnings are not in the result file (P13 can add); stats flow does not refresh at midnight until the next DB change; streak ignores weekday rest days; no skip-batch / pause / reorder-remaining buttons yet; retry log (per-attempt history) is only the last attempt’s output; sync is manual/on-open (no background pull, notifications = P16); `fire` still duplicates the plan/send steps of `runInner`.
- P13 notes: version 0.13.0 (versionCode 6). New `lib/github.sh` (~150 lines), `tests/mock_github.py`, `tests/test_p13.sh`; `bin/gitdrip`, `lib/bridge.sh`, `lib/git.sh`, config (`allow_create_repo:false`) extended. No Room change.
  - Transport `gh_api METHOD path [body]`: curl with the token passed via `-K -` (stdin) → never in argv/env/URL/logs; `GITDRIP_API` (default https://api.github.com; tests use a local mock), `GITDRIP_API_TIMEOUT` (15 s). Errors print `github: [class] msg`, classes: auth (401, 403 w/o rate-limit header, no token) | ratelimit (403 with `x-ratelimit-remaining: 0`, 429) | notfound (404) | transient (curl failure, 5xx) | fatal (rest, e.g. 422). Redirects followed (max 3). Slugs validated (`owner/repo`, no `.`/`..` segments); `gh_slug_from_url` accepts https/ssh github.com only (URLs with credentials → none).
  - CLI `gitdrip github whoami|repos|branches <o/r>|check <o/r>|create <name> [--public] [--desc T]` (JSON out, needs jq). whoami → login, id, name, `noreply_email` (`ID+login@users.noreply.github.com`), `token_kind` (classic|fine-grained from prefix), `user_matches` (stored `auth set --user` vs real login, case-insensitive). repos → ≤300 (3 pages), fields full_name/private/fork/archived/default_branch/html_url/push. branches → `{default_branch, branches[{name,default}]}` default first. check → repo shape + `eligible` (not fork, not archived, push) + `warnings[]`. create: refused unless config `allow_create_repo=true` (default false), private by default (`--public` opts out), `auto_init:false`, name validated; 422 → fatal.
  - Bridge (project-less, results/<req>.json `{state OK|ERROR, reason, error_class, data}`): `gh-validate | gh-repos | gh-branches <o/r> | gh-check <o/r> | gh-create <name> [--public]`.
  - Preflight (`_gh_elig`, only with token + jq + reachable API; silent otherwise): archived → BLOCK; fork → WARN; no push access → WARN; current branch ≠ repo default branch → WARN; else OK. Closes the P3/P5 "fork check deferred" gap. Bridge sync: when the plan has no user/email and the repo has no git identity, user = token owner's login, email = their noreply address (8 s API timeout, silent on failure).
  - Android: `data/GitHub.kt` (pure: `GhRepo.eligible`, `parseAccount/parseRepos/parseBranches`, `filterRepos`, `ghHint`), `GitHubUi.kt` (`GitHubAccountCard` on Setup screen = "Check token"; `RepoPickerDialog` repo → branch, hides forks/read-only unless switched on), VM P13 section (`ghCall` over the existing `poll`, `ghValidate/ghLoadRepos/ghLoadBranches`), New project gets "Pick from my GitHub repos" (fills repo URL + branch). Token stays in Termux; the app never sees it.
  - NOT verified: jq filters in github.sh/bridge.sh (part 2 of test_p13 never executed), any Kotlin/Compose/Gradle. Transport + slug logic verified against the mock (18/18); engine regression not re-run beyond test_p10 part 1 (8/8).
  - Known gaps: no app UI for repo creation (engine + bridge `gh-create` exist; needs `allow_create_repo` set in Termux); no multi-account picker (one token = one account; `credentials` holds one user); GitHub verified-email list (`/user/emails`) not fetched (fine-grained tokens can't); API results not cached (one call per preflight); `permissions.push` is the user's repo permission, not the fine-grained token's own scope; picker lists ≤300 repos.
- P14 notes: version 0.14.0 (versionCode 7). New `data/Secure.kt` (`Handoff` pure JVM + `Vault` Keystore), `tests/test_p14.sh`, `HandoffTest.kt`; `lib/auth.sh`, `lib/bridge.sh`, `lib/logger.sh`, `bin/gitdrip`, `GitHubUi.kt`, `MainViewModel.kt`, `TermuxBridge.kt`, `History.kt`, manifest extended. Room unchanged.
  - Handoff protocol: app generates a random 256-bit key (64 hex), writes `<ex>/handoff/<req>.enc` = openssl `enc -aes-256-cbc -pbkdf2 -md sha256 -iter 10000` blob ("Salted__"+salt+ciphertext) and sends ONE Intent `bridge <req> auth-handoff <user> <key>`. Engine `auth_handoff` (lib/auth.sh): key read from a pipe (never argv of any child), file must be a regular non-symlink ≤1 KB, decrypts with `openssl enc -d … -pass stdin`, pipes plaintext into `auth_set` (format-checked, chmod 600). The `.enc` file is deleted on EVERY path (success, wrong key, bad token, bad user/key, oversize); symlinks refused (target untouched). Result `results/<req>.json` = `{state OK|ERROR, action auth-handoff, reason}` with no token/key; works without jq. Doctor now reports `tools.openssl` and removes `handoff/*.enc` older than 10 min. Setup command installs `openssl-tool`.
  - Residual risk (accepted): the one-time key is an Intent extra → Termux argv (`/proc/<pid>/cmdline` readable only by Termux uid/root); ciphertext sits in shared storage for seconds, useless without the key and deleted after use. Logs redact `auth-handoff <user> <64hex>` (engine `_log_redact` + app `redact`).
  - Android: `Handoff` (validToken/validUser mirror engine regexes, `newKeyHex`, `encrypt`), `Vault` (AndroidKeyStore AES-256-GCM key, non-exportable, blob `filesDir/vault.bin` = iv+ct; no user-auth requirement because alarms run unattended; `load` returns null if the key is lost), VM `sendToken/resendSavedToken/forgetSavedToken` (validate → optional Vault save → write .enc → send → poll ≤30 s → always delete .enc + result → auto "Check token"), Setup screen `TokenSection` (password field, no autocorrect, `FLAG_SECURE` while visible, "keep encrypted copy" switch, Re-send / Forget saved).
  - Permission audit (enforced by test_p14): exactly MANAGE_EXTERNAL_STORAGE (Termux exchange folder), RUN_COMMAND, SCHEDULE_EXACT_ALARM, RECEIVE_BOOT_COMPLETED. No INTERNET (app never talks to GitHub; token only to Termux), `allowBackup=false`, `usesCleartextTraffic=false`, only `MainActivity` exported (BootReceiver now `exported=false`; system broadcasts still reach it).
  - NOT verified: Kotlin compile, Keystore on device, FLAG_SECURE, RUN_COMMAND with the new args, `openssl-tool` on-device behaviour (flags tested with OpenSSL 3.0.13 here).
  - Known gaps: Kotlin `String` token can't be zeroed from memory; token still lives in Termux `credentials` (chmod 600, Termux-private); no passphrase/biometric gate on the Vault; no token expiry reminder; `MANAGE_EXTERNAL_STORAGE` is Play-restricted (sideload only).
- P7.5 notes: version 0.17.0. New `lib/prflow.sh` (~190 lines), `tests/test_p75.sh` (31 checks, includes P13 regression); `bin/gitdrip` (cmds `issue`, `pr`, `pr-flow`), `tests/mock_github.py` (issues/pulls/merge/delete branch), `lib/common.sh` version, version asserts in test_p10/test_p16. No Android change; no new config key.
  - CLI: `gitdrip issue create <o/r> --title T [--body B]`; `gitdrip pr open <o/r> --head BR --title T [--base BR] [--body B]` (base defaults to repo default branch via API); `gitdrip pr merge <o/r> <n> [--method squash|merge|rebase]`; `gitdrip pr-flow <p> <batch-id> [--issue] [--merge] [--method M] [--dry]`. All JSON out, token only via `gh_api` (stdin curl config), slugs/branch names/method validated BEFORE any request.
  - `pr-flow` = the normal real batch commit (reuses `git_run_batch`: secret scan, preflight, only batch files, never empty, never backdated, never force) but on branch `gitdrip/<project>-batch-<id>` cut from the repo default branch (API-reported; fork/archived/no-push repo refused before any branch/write). Steps: lock project (exit 4 if live) -> dirty tree refused -> fetch + ff local base (offline = warn, continue; diverged local base = die) -> branch -> commit + push branch -> [issue (`--issue`, body = file list)] -> PR (title = batch message, body `Batch N of project P` + `Closes #issue`) -> [`--merge`: PUT merge, delete remote branch, ff local base, drop local branch] -> back on base.
  - Idempotent/resumable: SUCCESS/NOCHANGE batch = no-op (no new PR); existing open PR for the head branch is reused (`gh_pr_find`); push failure leaves batch COMMITTED + branch kept, rerun pushes the SAME commit (no duplicate) and opens the PR; no change -> exit 3, branch removed, no PR; failure with no commit (e.g. `secret_blocked`) -> branch removed, batch stays PENDING. Merge refused by GitHub (e.g. method not allowed) -> exit 1, PR stays open, batch stays SUCCESS (pushed), branch kept. Batch is stored with `pr`, `pr_url`, `issue` fields in `batches.json`.
  - Merge is opt-in per run (`--merge`); default leaves the PR open for review. A batch committed outside pr-flow (COMMITTED, no branch) is refused ("push it with gitdrip run"). Unmerged PR batches are NOT on local/remote default branch, so later batches branch from a base without them (fine: batches are disjoint files).
  - Contribution note: PRs/issues/merges count on the graph only for real work; squash-merge commit lands on the default branch with the PR author, so it counts as a commit; the feature-branch commit itself does not. Token needs Issues + Pull requests + Contents write (fine-grained) or `repo` (classic).
  - NOT verified: real GitHub API (mock only), merge-method restrictions per repo, branch protection / required reviews (merge simply fails -> exit 1), draft PRs, PR labels/reviewers. Known gaps: no bridge action / app button for pr-flow yet; `pr-flow` does not use the task runner (no task JSON, no retry/PENDING_RETRY, not scheduled by cron/app) - manual CLI only; no `--draft`; issue created per batch only with `--issue`; remote branch not deleted without `--merge`.
- Primary goal: grow the GitHub contribution graph through REAL, steady commits (see CONTRIBUTION RULES)

## Rules
- 1 phase = 1 chat session. Never start two phases in one chat.
- Each phase: ≤ 8 files, ≤ ~500 lines new code, one verifiable "Done when".
- Start each chat by uploading ONLY: plan.md + files listed under "Upload".
- End each chat with: updated plan.md + full project zip (single zip).
- Integrity: commits must contain real project changes only. No empty/dummy commits.
- Secrets: never in repo, args, or logs.

## Design changes vs original plan
1. Build Termux engine FIRST (testable with plain bash, no Android needed), Android UI second.
2. App-private storage (/data/data/...) is NOT readable by Termux. Use shared dir
   (/storage/emulated/0/GitDrip/ ↔ ~/storage/shared/GitDrip/) as exchange folder, or push files via Termux RUN_COMMAND.
3. Use Termux `RUN_COMMAND` intent (needs `allow-external-apps=true` in ~/.termux/termux.properties
   + `com.termux.permission.RUN_COMMAND`), NOT `termux-job-scheduler`.
4. Scheduling: Android AlarmManager/WorkManager triggers the intent; Termux crond (termux-services) is the
   fallback. Drop "hybrid with persistent state" until P14.
5. Use Termux from F-Droid/GitHub only (Play Store build is dead).
6. Auth = fine-grained PAT only until MVP works. OAuth deferred (needs backend).
7. State of truth = JSON files in Termux (tasks/*.json); Room mirrors them. Android sends task_id only.

---

# TRACK A — Termux Engine (bash, no Android)

## P1 — Skeleton + config  (~150 lines)
- Build: dir layout, `config.json`, `logger.sh`, `bin/gitdrip` CLI dispatcher, `install.sh`
- Upload: nothing
- Done when: `gitdrip --help`, `gitdrip log "test"` writes to logs/execution.log

## P2 — Manifest + batch file format  (~200 lines)
- Build: `manifest.json` generator (sha256, size), `batches.json` schema, `gitdrip import <dir>`, `gitdrip batch-create`
- Upload: P1 zip
- Done when: import a sample folder → manifest + 3 batches generated ✔

## P3 — Git engine  (~250 lines)
- Build: `git.sh` (init, status, diff check, add specific files, commit, push, branch), no-change = STOP
- Upload: P2 zip
- Done when: `gitdrip run-batch <project> 1` commits+pushes to a test repo; rerun does nothing

## P4 — Task runner + state machine  (~250 lines)
- Build: `runner.sh`, task JSON states (PENDING→RUNNING→SUCCESS/FAILED), lock file, idempotency
- Upload: P3 zip
- Done when: running same task twice → second is skipped; stale lock handled

## P5 — Auth + safety checks  (~250 lines)
- Build: token via `~/.gitdrip/credentials` (chmod 600) + git credential helper, secret scanner (ghp_, AKIA, private keys, .env), `.gitignore` merge
- Upload: P4 zip
- Done when: staging a file with fake token BLOCKS commit; token never appears in logs

## P6 — Retry + offline handling  (~200 lines)
- Build: `retry.sh` (backoff 0/2/5/15 min), error classifier (transient vs fatal), PENDING_RETRY, verify-commit-before-retry
- Upload: P5 zip
- Done when: airplane-mode test → retries → succeeds once online, no duplicate commit

## P7 — Scheduler (Termux side)  (~150 lines)
- Build: crond job via termux-services, `gitdrip schedule add "<HH:MM>" <project>`, next-batch picker, missed-task policy
- Upload: P6 zip
- Done when: scheduled job fires at set time and pushes next batch

**★ CHECKPOINT (REACHED): Termux-only MVP is fully usable here. Stop and use it for a week if needed.**

---

# TRACK B — Android Control Plane

## P8 — Android foundation  (~400 lines)
- Build: Compose project, Navigation, Room (projects, batches, schedules, executions), Dashboard shell, Project CRUD
- Upload: plan.md only
- Done when: app runs, create/list/delete project

## P9 — Import + batch manager UI  (~450 lines)
- Build: SAF picker (files/folder/ZIP), copy to shared GitDrip dir, SHA-256, batch create/reorder/assign
- Upload: P8 zip
- Done when: import folder → see files → create 3 batches

## P10 — Termux bridge  (~350 lines)
- Build: Termux detection, RUN_COMMAND intent, permission/setup guide screen, task_id passing, result file polling/PendingIntent callback
- Upload: P9 zip
- Done when: "Run batch now" button → Termux executes → status shows in app

## P11 — Schedule UI + AlarmManager  (~350 lines)
- Build: schedule create/edit, exact alarm trigger → Termux intent, timezone (UTC + zone), boot receiver, battery-optimization prompt
- Upload: P10 zip
- Done when: scheduled time fires after app swiped away; survives reboot

## P12 — Execution history + dashboard  (~300 lines)
- Build: history list/detail (commit hash, files changed, stdout/stderr redacted), dashboard stats, sync from Termux JSON
- Upload: P11 zip
- Done when: success + failed runs both visible with details ✔ (code; unbuilt)

**★ CHECKPOINT (REACHED, code-complete): Full MVP (Section 37 of original plan). Needs an Android Studio build + on-device pass.**

---

# TRACK C — Hardening & Extras

## P13 — GitHub API  (~250 lines) ✔ code done
- Build: validate token, list repos/branches, optional create repo (default OFF), account picker UI
- Upload: P12 zip

## P14 — Android security  (~250 lines) ✔ code done
- Build: Keystore-encrypted token, secure token handoff to Termux, minimal permissions audit, log redaction
- Upload: P13 zip

## P15 — Test pass  (~300 lines tests + fixes)
- Test matrix: fresh install, Termux missing, invalid token, offline, reboot, duplicate run, simultaneous tasks, failed push, permission error, timezone change
- Upload: P14 zip + list of failing cases

## P16 — Polish  (~350 lines)  ✔ code done (P16 engine+dark mode, P16b notifications/a11y/backup UI)
- Notifications, dark mode, accessibility, import/export config, backup/restore
- Upload: P15 zip

## P17 (optional) — OAuth
- Needs a backend for token exchange. Only if publishing for other users.

---

## Free-tier survival tips
- Upload zips only when needed; otherwise paste just the 1–3 files being edited.
- Ask for code only; request diffs/changed files instead of full rewrites after P8.
- If a phase hits a limit mid-way: stop, zip what exists, note "P# partial: <what's left>" under STATUS, resume next window.
- Split any phase marked >350 lines into "a" (data/logic) and "b" (UI) if limits are tight.

## Phase log
| Phase | Status | Date | Notes |
|---|---|---|---|
| P1 | DONE | 2026-10-03 | 9/9 tests pass; Termux on-device install untested |
| P2 | DONE | 2026-10-03 | 17/17 tests pass; module = directory; on-device untested |
| P3 | DONE | 2026-10-03 | 21/21 tests pass; local bare-remote only; real GitHub push untested (needs P5 auth) |
| P4 | DONE | 2026-10-04 | 26/26 tests pass (incl. P1–P3 regression); concurrent-run + stale-lock tested locally; on-device untested |
| P5 | DONE | 2026-10-04 | 38/38 tests pass (incl. P1–P4 regression); real HTTPS push with PAT untested (needs device/network) |
| P6 | DONE | 2026-10-04 | 23/23 tests pass (incl. P1–P5 regression); offline simulated via GITDRIP_NET, transient push via closed local port; on-device untested |
| P7 | DONE | 2026-10-04 | 21/21 tests pass (incl. P1–P6 regression); fake crontab + GITDRIP_NOW clock; real crond firing on-device untested |
| P8 | CODE DONE, UNBUILT | 2026-10-04 | ~320 Kotlin lines; needs Android Studio sync + run to confirm |
| P9 | CODE DONE, UNBUILT | 2026-10-04 | ~430 Kotlin lines; Batching logic 8/8 verified via kotlinc; Android parts unverified |
| P10 | CODE DONE, UNBUILT | 2026-10-05 | engine bridge part 1 8/8 pass; part 2 + Kotlin/Android unverified (no jq/kotlinc/Gradle) |
| P11 | CODE DONE, UNBUILT | 2026-10-05 | ~330 Kotlin lines; ScheduleMath tests written, not run |
| P12 | CODE DONE, UNBUILT | 2026-10-04 | engine history 33/33 (incl. P1–P7 regression); 33 pure-Kotlin JVM tests pass; Compose/Room unverified |
| P13 | CODE DONE, UNBUILT | 2026-10-04 | engine transport 18/18 vs mock; jq part (~40) + Kotlin unverified (no jq/kotlinc in sandbox) |
| P14 | CODE DONE, UNBUILT | 2026-10-04 | engine handoff/audit 25/25 (+P10/P13 part-1 regression); KAT matches openssl; Kotlin/Keystore unverified |
| P15 | PARTIAL | 2026-10-04 | engine 100% green incl. jq parts (1 bug fixed: create-repo body); 61 pure-Kotlin tests pass (45 + 16 org.json); Gradle/device pass pending |
| P16 | CODE DONE, UNBUILT | 2026-10-04 | engine backup/restore/config export-import 20/20 (jq import checks unrun); dark mode unverified |
| P16b | CODE DONE, UNBUILT | 2026-10-04 | engine bridge backup/restore/cfg 33/33 (incl. P16, jq import unrun); notifications + a11y + Settings UI Kotlin unverified (no kotlinc/Gradle) |
| P15b | SANDBOX + GRADLE DONE | 2026-10-04 | engine suites + 61 Kotlin JVM tests green; user Gradle 8.7 `./gradlew test` BUILD SUCCESSFUL (debug+release compile, unit tests); device pass pending |
| P7.5 | DONE (engine) | 2026-10-04 | pr-flow 31/31 vs mock + P1-P16 regression green; real GitHub untested; no app/bridge hook |
| P17 | Not started | | |


---

# APP WORKFLOW (user-facing)

## A. One-time setup (P10 setup screen)
1. Install Termux (F-Droid/GitHub) + GitDrip.
2. App checks: Termux installed → RUN_COMMAND permission granted → `allow-external-apps=true` set → `~/storage` linked → git/curl/jq installed.
3. App shows a one-tap copyable setup command if anything is missing.
4. Add GitHub account: paste fine-grained PAT → app validates via `GET /user` → stored in Keystore (P14) / Termux credentials file (chmod 600).
5. Disable battery optimization for GitDrip + Termux.

## B. Create project
Dashboard → "+ Project" → name → choose GitHub repo (existing, default) → branch → auto-create repo OFF → save.

## C. Import & organize
1. Project → Import → pick files / folder / ZIP (SAF).
2. App copies to shared GitDrip/<project>/source and computes SHA-256 manifest.
3. Secret scan runs immediately; flagged files (.env, keys) are excluded and shown.
4. Auto-suggest batches (by folder/type) → user renames, reorders, moves files between batches.
5. Each batch = meaningful unit + commit message (e.g. "feat: add auth module").

## D. Schedule
1. Project → Schedule → pick time(s), days, timezone, retry limit, missed-task policy (skip / run now / next slot).
2. Mapping: each slot consumes the next PENDING batch in order.
3. App registers AlarmManager alarm (+ Termux crond fallback).

## E. Execution (automatic)
```
Alarm fires
  → app creates task_id (state: SCHEDULED) in Room
  → RUN_COMMAND intent → Termux runner.sh <task_id>
  → validate task + SUCCESS? skip : continue
  → acquire project lock
  → network check (offline → PENDING_RETRY)
  → load batch → copy batch files into repo
  → git diff: no change → STOP (no empty commit)
  → secret scan (hit → BLOCK, notify user)
  → git add <files> → commit → push
  → push OK → SUCCESS, write result JSON (hash, files changed)
  → release lock
App reads result → updates Room → notification
```

## F. Failure handling
- Transient (timeout/DNS/5xx): retry 0 → +2 → +5 → +15 min; verify commit exists before re-push.
- Fatal (bad token, permission, merge conflict, invalid repo): stop, notify, user fixes → "Retry" button.
- Reboot: BOOT_COMPLETED → reload schedules → apply missed-task policy.

## G. Monitor
- Dashboard: projects, active schedules, today's tasks, success/fail counts, next run, progress per project.
- History: per run → batch, start/end, commit hash, files changed, repo link, redacted stdout/stderr, retry log.
- Manual actions: Run now, Skip batch, Retry, Pause project, Re-order remaining batches.

## H. Screen map
Dashboard → Projects → Project Detail (Files | Batches | Schedule | History) → Run Detail
Dashboard → GitHub Accounts · Settings (policies, notifications, backup/restore, setup check)


---

# CONTRIBUTION RULES (primary goal)

## What GitHub counts
- Commit author email = a verified email on the account (or the `ID+user@users.noreply.github.com` address).
- Pushed to the default branch (or gh-pages) of a non-fork repo.
- Private-repo activity only shows if Profile → Contribution settings → "Private contributions" is ON.
- Date shown = commit author date → real work pushed on real days.

## What the app does
- One commit = one small meaningful unit (module/screen/endpoint/test/doc). Target 1–5 files per batch.
- Daily slot count configurable (e.g. 1–3/day), spread across the day.
- Each phase of any project is split into many small batches instead of one big commit.
- NEVER: empty commits, dummy/touch-file edits, backdated commits, duplicated files, or scripted noise.

## Plan adjustments
- P2: batch suggester caps batch size (default ≤5 files) and splits by module; shows "commits available" count.
- P3 (done): preflight `git config user.email` vs GitHub verified/noreply email; warn on mismatch; block pushes to a fork or non-default branch (warn only).
- P5: add "contribution eligibility" check to the safety preflight.
- P8–P9: setup screen reminds user to enable "Private contributions" if repos are private.
- P12: dashboard shows "eligible commits today / this week / streak" next to success counts.


---

# RECOMMENDED PATH (v2 improvements)

1. **Ship Track A only (P1–P7) first.** Termux CLI + crond already does the whole job; the Android app (Track B) is a convenience UI. Saves ~60% of effort/tokens and removes Android background-kill risk.
2. **Count more than commits.** Graph also counts PRs, issues, reviews. Per phase of any project: issue -> feature branch -> PR -> merge. Added as P7.5 (done): `gitdrip pr-flow` via the REST API (no gh CLI needed). Next: bridge/app button + scheduler integration.
3. **Commit while building, not after.** Add a `gitdrip watch`/post-save hook so real work is committed in small steps on the day it's written; drip-scheduler only covers the backlog.
4. **Publish the backlog.** Many existing local projects/zips are unpublished or committed in one dump. Import each, split into module batches, push with proper README, .gitignore, and tests (also improves profile quality: pin 6 best repos).
5. **Quality over count.** Profile shows pinned repos + README; reviewers look at those. Add a profile README (stats, stack, projects) and good repo descriptions/topics.
6. **Weekly cap + variety.** Config: max N commits/day, rest days allowed, real commit messages (conventional commits), mix of feat/fix/test/docs.
7. **Dry-run mode** (`gitdrip run --dry`) before any push.
