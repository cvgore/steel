# Workout operations and durable state (STEEL-8)

The existing phone Core Data graph is authoritative. `WorkoutOperationStore` changes the graph, session version, absolute rest and operation disposition in **one persistent-store save** using a fresh private context. UI drafts and other unsaved view-context changes are never committed incidentally. `apply(operation:mergingInto:)` merges the successful save before its caller updates selection or runs effects.

Shared value types live in `Shared/WorkoutSession`, compiled into WorkoutDataKit and WatchIron. Watch does not import the phone framework or persist a second phone graph. `WorkoutReplicaStore` owns one atomic JSON file under private Application Support, including the accepted snapshot, local projection, operations, receipts and conflicts. WorkoutSessionManagerStore retains the default shared owner, exposing load failure without clearing its outbox. Callers must retain one owner per file; reload creates a new owner only after the previous owner stops being used.

## Phone commands and receipts

A `WorkoutOperation` has a stable `id`, `workoutID`, optional `sessionID`, durable `originID`, `sequence`, optional `predecessorID`, `expectedVersion`, mutation and absolute date. Phone-local commands use origin `phone`; remote operations require the matching phone-created session identity and a positive sequence. No transport message ID may replace the operation ID.

Mutations cover planned-set completion/correction or an uncompleted draft save, exercise/set order, phone-only structure changes, exercise comments, workout metadata and start/end time, absolute rest, and finish/cancel requests. Set payloads preserve nil separately from zero, UUID parents and existing metadata. Limits, RPE, defaults and completion order rules are shared with the existing phone models; unit conversion remains the existing WeightUnit implementation.

`apply` returns a durable `WorkoutOperationReceipt`:

| Disposition | Meaning | Retry |
| --- | --- | --- |
| `applied` | Graph/state/version and receipt committed together | Return identical receipt before current-version checks |
| `conflict` | Full original input retained; accepted graph unchanged | Return identical conflict, never silently apply it |
| `waitingForPredecessor` | Original operation retained but its predecessor is missing or still waiting | Re-evaluate after predecessor arrives; retain the same ID and payload |

Reusing an ID with a different payload throws `operationIDCollision`. Invalid scalar values and foreign parents on an applicable command throw without a partial save. A stale candidate is retained even when its target was deleted since its base; graph-dependent validation runs only for an applicable command. `operations(workoutID:disposition:)` exposes the full durable candidates and receipts. STEEL-9 adds an explicit resolution operation and phone UI; no transport retry chooses a winner.

Only a first completion changes completion, applies Iron's existing exercise reordering rule and records the operation date/rest duration. A correction changes the same set's result and metadata without changing completion, rest or order. Effects and selection progression depend on an **applied** receipt with `didComplete == true`; a receipt alone is not permission to repeat effects on every transport retry.

## Versions and offline ordering

Phone accepted version and Watch `localRevision` are different counters. A Watch edit increments localRevision and stores its result plus operation atomically; it does not pretend the phone accepted it.

Uncovered sequential operations name their immediate predecessor and retain that predecessor's base version, including when an intermediate snapshot covers an earlier operation in the chain. The phone verifies matching workout/session/origin and consecutive sequence. Once the predecessor is applied, its accepted version becomes the successor's causal base. The successor applies only if the phone has not advanced beyond that predecessor; concurrent phone edits produce a durable conflict, and a conflicted predecessor produces a successor conflict.

A fresh edit after a covering snapshot uses that snapshot's accepted version and needs no predecessor, even if its origin sequence is greater than one. Sequence remains monotonic. Replay follows predecessor/sequence and accepted version, not wall-clock timestamps or array iteration order. A successor received first returns `waitingForPredecessor`; it is not treated as applied or dropped. There is no generic synchronization queue or independent phone journal.

## Snapshots, receipts and pending Watch results

`WorkoutSessionSnapshot` carries ordered instance UUIDs, nullable results, target ranges, tags/RPE/comments, workout metadata, session phase, accepted version, absolute rest and `coveredOperationIDs` containing only applied operations. Selection, drafts and navigation remain local.

A receipt acknowledges durable phone processing. Snapshot coverage proves the accepted snapshot includes that operation. These are independent facts: ack-before-snapshot retains the local result; snapshot-before-ack leaves the operation available for retry. Watch retains operation records and overlays every uncovered local mutation on the accepted base. An intermediate snapshot covering a valid prefix of a local chain keeps its successor without inventing a conflict.

Older snapshots are ignored. A divergent snapshot preserves both the accepted phone graph and local candidate in durable conflict state. Removing a pending target cannot erase the candidate. Conflicting receipt inputs remain in operation/receipt state; pending transport access excludes final receipts but never deletes their candidate data. Failed atomic writes leave both in-memory state and the previous file unchanged.

## Durable session APIs

| Phase | Data meaning |
| --- | --- |
| `local` | Existing phone-only workout; no shared slot |
| `joining` | Phone-created session persisted, Watch waiting |
| `agreed` | Explicit agreement persisted; Watch editing permitted |
| `pendingFinish` / `pendingCancel` | Durable request; shared slot remains occupied |
| `finished` / `cancelled` | Durable terminal marker; late snapshots cannot reopen it |

Phone API: `beginJoining(workoutID:mergingInto:)` creates/reuses the identity and rejects another unresolved shared slot. `recordSessionAgreement(workoutID:sessionID:phase:mergingInto:)` records joining→agreed or pending→matching-terminal; duplicate agreement is idempotent. Terminal agreement requires no waiting/conflicted operations and clears durable rest. STEEL-13 adds atomic graph pruning/cancellation at terminal agreement and a separate HealthKit effect lifecycle, described below.

Watch API: `adopt(snapshot:)` persists the phone-created session, `agree(sessionID:)` durably enables edits, `submit(_:id:date:)` stores a local mutation and operation, and `receive(receipt:)` persists disposition. Receiving an agreed snapshot alone does not bypass explicit durable agreement. Finish/cancel use the same outbox and predecessor chain. Only a resolved, covered and acknowledged terminal session can be replaced; its snapshots, operations, receipts and conflicts are archived in the same file, and terminal markers remain to reject replay.

STEEL-9 implements joining/ack scheduling and WatchConnectivity exchange as described below. Existing measurement preparation stays separate. There is no Watch-created workout or new Watch editor in this task.

## Phone writer inventory and rest recovery

- `CurrentWorkoutView`: active workout title/comment drafts and exercise addition/removal/order use `WorkoutCommandWriter`.
- `WorkoutExerciseDetailView`: result and metadata draft submission, active set addition/removal and exercise comments use the same boundary. Editing captures a base version; it follows only contiguous known local commits that leave the selected result intact and cannot silently rebase onto a concurrent remote change. Failed submission keeps the draft and selection. Leaving or changing selection discards unsubmitted set drafts.
- `WorkoutSetEditor`: weight/reps, tag, RPE and comment bind to a local value draft, never directly to managed fields.
- `EditCurrentWorkoutTimeView`: active start/end DatePicker, automatic tracking and reset use a validated time command; direct managed-object time bindings are removed. The command validates finite ordered dates and preserves active-workout status.
- `RestTimerStore` / `RestTimerView`: pair updates use one absolute-rest command; committed receipts only project to UserDefaults and effects. Startup/foreground restores the durable pair, including expired intervals and explicit cancellation. Stale displayed rest cannot overwrite a newer durable interval.
- `WorkoutDetailView` delegates active workouts to CurrentWorkoutView; its direct history date/order edits remain historical. Start/copy construct the original graph before shared identity exists. Shared finish/cancel now use STEEL-13 terminal reconciliation; phone-only finish/cancel retain the existing domain flow.
- Existing phone WatchConnectivity receives preparation status only; future received mutations must call this store, never write managed fields directly.

## Migration and backup compatibility

Historical models/mappings remain intact. v5 adds session/operation records, v6 adds durable phase. Legacy v1–v3 stores migrate via the existing explicit mappings to v4, then inferred migration to current; additive v4/v5 sources migrate directly. Tests cover UUIDs, ordering, nil values, metadata and retry of the first-slice v5 encoded operations/receipts. Unknown models are rejected, never erased.

Backup stays version 3 and excludes session/operation/transport state and active workouts. Restore atomically clears metadata belonging to replaced history while preserving the current workout's identity and receipts. Optional `weightWasNil` / `repetitionsWereNil` markers retain nil versus zero while leaving legacy numeric scalar fields readable by older decoders. Existing JSON/backup fixtures remain readable. Backup restore cannot recreate an agreed channel to an old device.

## Verification

92 XCTest tests passed, including both durable stores across restart/out-of-order delivery/lost receipts, deleted-target conflicts, sequential offline edits, terminal safeguards, UI writer/rest recovery, migrations v1–v5 and backup/JSON roundtrips. The production-app XCUITest passed workout start-time reset and rest start/increase/cancel while a set draft is open, completion, correction without progression, finishing and persisted history after relaunch. WatchIron builds passed Debug and Release with pinned packages and ad-hoc signing. Localization/catalog validation and git diff checks passed.


## STEEL-9 transport and recovery

`WorkoutSyncMessage` is a versioned Codable payload under `workoutSync.v1`. Phone starts durable joining independently of HealthKit preparation. Watch adopts the joining snapshot atomically before replying with workout/session UUIDs. Phone durably records agreement and sends the agreed snapshot; only then does Watch persist its editing agreement. Duplicate joins reuse the same session and version. Preparation messages never grant workout editing permission.

The existing managers send immediate messages when reachable, deferred user-info delivery otherwise, and retain the selected phone session in application context while preserving language and other fields. Activation, reachability and Watch foreground resume request durable state. Watch retries unanswered joining, operations and snapshot coverage while reachable. The outbox remains STEEL-8's replica operations, not another domain queue. Data load failures remain errors rather than replacing the replica.

Phone re-evaluates durable waiting successors in sequence after applying a predecessor. Each operation retains its ID and payload across all transports. Update replies include the accepted snapshot and durable receipts; Watch can also recover them by requesting its workout/session. Receipts never stand in for snapshot coverage. Both stores retain original absolute rest times; presentation restores those times without issuing another command. Legacy tracking date/rest messages cannot replace shared snapshot values; old starts cannot replace an unresolved session or resurrect a terminal workout. Old-session replies cannot replace the active session's presentation or latest-state context.

Snapshots carry `editorContext`: units, keep-running setting, active exercise labels/rest rules, initial barbell weight in metric units, and numeric default templates for active exercises. These templates contain only weight/repetition pairs, truncated to planned set count and deduplicated, with no historical workout identities, dates, comments or graph. The phone editor and Watch snapshot use the same `WorkoutEditingRules.initialDraft` function, including history-prefix matching and offline fallback to the previous local set. Phone snapshots evaluate every completed set with the existing `WorkoutSet.isPersonalRecord`; Watch clears confirmed flags throughout an affected exercise after an offline result until phone verification arrives. Presentation-only updates at the same domain version do not create conflicts.

## Explicit conflict decisions

The phone's Watch synchronization sheet displays accepted and proposed values and offers a decision. `resolveConflict(operationID:useCandidate:)` is a phone-authored operation with its own stable ID and expected version. It commits the selected candidate (or keeps the accepted graph), decision receipt and next version in the same store transaction. The original operation and conflict receipt are retained. Resolution validates the session in the durable receipt, including older phone operations whose original payload did not contain a session ID. Keeping the saved graph can dismiss other stale phone commands before the user repeats the edit in its original editor; applying a proposed candidate is limited to set results and terminal requests. An exact decision retry returns its existing receipt; a stale decision fails before writing and requires refreshed values. Applying a candidate validates its current target; a deleted target can still be resolved by keeping the accepted graph.

`unresolvedConflictIDs` advertises server conflicts even when Watch has no local candidate/receipt (for example a stale phone draft). Watch retains advertised IDs across same-version or delayed snapshot delivery until `resolvedOperationIDs` explicitly settles them. Presentation-only summaries never masquerade as workout edits. `resolvedOperationIDs` in snapshots identifies explicitly settled candidates separately from applied-operation coverage. Watch stops overlaying those candidates but retains their original inputs/receipts/history, including after restart. Further offline edits begin from the resolved accepted version. Descendants that also conflict require their own explicit decisions. Terminal agreement rejects any unresolved waiting/conflicting operations; resolved candidates no longer block it. Terminal requests themselves remain pending and retain the shared slot. Domain finish/cancel, pruning, journal deletion and HealthKit effects remain STEEL-13.

The minimal Watch status view reports waiting, pending changes and errors; conflicts direct the user to the phone's decision sheet. It does not change selection/navigation or implement STEEL-10–12's workout editor. Physical/background acceptance remains STEEL-14, separate from the protocol tests and simulator builds.


### STEEL-9 verification and integration limits

Verification in this worktree on 2026-11-02: 109 XCTest tests passed (including durable join, out-of-order operation transport, conflict decisions/retry/restart, correction racing finish, terminal replay guards, editor defaults and record recalculation/ties); WatchIron Debug and Release simulator builds passed; the production phone workout/history-after-relaunch XCUITest passed; localization/catalog validation and `git diff --check` passed. Build/test SDKs were Xcode 27 / iOS 27 / watchOS 27, with pinned packages and ad-hoc signing.

STEEL-7's prepared project/configuration changes were subsequently integrated from its separate worktree: deployment minimums are now iOS/watchOS 26.0 and unused WatchKit extension references are removed. Integration is verified separately with SDK/runtime 27 and deployment minimum 26; these are distinct versions. Physical paired/background acceptance remains STEEL-14. This change does not implement STEEL-10–12's Watch workout editor, STEEL-13's domain/HealthKit finalization, or STEEL-16's rebranding.

## STEEL-13 shared completion and measurement effects

The Finish page submits the same durable `requestFinish`/`requestCancel` mutations as the phone. Cancel uses a system confirmation. An agreed request keeps the current graph and shared slot pending, including after restart. Its timestamp fixes the finish time; synchronization delay does not lengthen the workout.

Watch replies with `terminalReady(workoutID:sessionID:version:)` only after every local operation has a durable receipt and accepted snapshot coverage or an explicit conflict decision. A new join that overtakes the old terminal reply is retained in the same replica; the Watch recovers the old session before adopting the offer. Measurement-start requests that overtake that reconciliation are retained in the replica and resumed after adoption, with acknowledgment only after collection succeeds. A serial runtime gate blocks prepare/start until active-session recovery attaches its owner or confirms absence, and duplicate starts cannot acknowledge an in-flight collection. Recovery errors keep the gate closed and expose retry status. Readiness is reconstructed from the existing replica and retried through the existing transport; there is no separate queue. A phone transaction checks the exact version and absence of unresolved operations before finishing. Concurrent results remain explicit conflicts, and decisions advance the version so stale readiness cannot finalize them.

Finalization clears rest and either preserves completed results with the existing unfinished-set/exercise pruning or deletes the cancelled graph. The phase, version, graph changes and terminal snapshot are saved together. Additive model v7 retains that terminal snapshot independently of the graph, so cancellation, late joins and duplicate requests remain answerable after restart. Original operation payloads and receipts remain available. A phone request while still joining can finalize immediately because Watch editing has never been authorized. Phone-only (`local`) workouts retain their previous finish/cancel path.

Shared sessions reserve measurement ownership for Watch. Neither normal phone finalization nor bulk Health synchronization creates or replaces a Watch-owned Health workout based on missing query results. Watch records an effect claim in its replica **before** calling HealthKit; journal completion does not depend on HealthKit success. Shared saving uses the existing builder once and does not copy/save another workout to adjust its start date. The journal retains the agreed dates; Health retains the measured start.

Terminal adoption atomically schedules a `pending` effect, retained even if a new session archives the old one before measurement handling runs. The effect states are `pending`, `saving`, `saved`, `blocked`, `uncertain` and `discarded`. A restarted in-flight save becomes uncertain. “Check measurements” checks all uncertain effects independently, so an unreadable older effect cannot block later recovery. It can positively identify an existing Health workout by its external UUID; an empty/failed query never authorizes another write, because permission may hide a saved sample. A blocked effect can be explicitly retried before any Health save attempt, after permission/session recovery. Recovery status survives subsequent shared sessions; unresolved earlier effects remain visible alongside current pending/conflict status. Cancellation discards measurement collection without writing a Health workout. Physical permission, sensor, recovery and background behavior still require paired-device acceptance under STEEL-14.
