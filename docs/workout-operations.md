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

Reusing an ID with a different payload throws `operationIDCollision`. Invalid scalar values and foreign parents on an applicable command throw without a partial save. A stale candidate is retained even when its target was deleted since its base; graph-dependent validation runs only for an applicable command. `operations(workoutID:disposition:)` exposes the full durable candidates and receipts. Conflict resolution policy and UI belong to STEEL-9; STEEL-8 does not choose a winner.

Only a first completion changes completion, applies Iron's existing exercise reordering rule and records the operation date/rest duration. A correction changes the same set's result and metadata without changing completion, rest or order. Effects and selection progression depend on an **applied** receipt with `didComplete == true`; a receipt alone is not permission to repeat effects on every transport retry.

## Versions and offline ordering

Phone accepted version and Watch `localRevision` are different counters. A Watch edit increments localRevision and stores its result plus operation atomically; it does not pretend the phone accepted it.

Uncovered sequential operations name their immediate predecessor and retain the accepted snapshot's base version. The phone verifies matching workout/session/origin and consecutive sequence. Once the predecessor is applied, its accepted version becomes the successor's causal base. The successor applies only if the phone has not advanced beyond that predecessor; concurrent phone edits produce a durable conflict, and a conflicted predecessor produces a successor conflict.

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

Phone API: `beginJoining(workoutID:mergingInto:)` creates/reuses the identity and rejects another unresolved shared slot. `recordSessionAgreement(workoutID:sessionID:phase:mergingInto:)` records joining→agreed or pending→matching-terminal; duplicate agreement is idempotent. Terminal agreement requires no waiting/conflicted operations and clears durable rest. These APIs record state only: graph pruning, cancellation and HealthKit are STEEL-13.

Watch API: `adopt(snapshot:)` persists the phone-created session, `agree(sessionID:)` durably enables edits, `submit(_:id:date:)` stores a local mutation and operation, and `receive(receipt:)` persists disposition. Receiving an agreed snapshot alone does not bypass explicit durable agreement. Finish/cancel use the same outbox and predecessor chain. Only a resolved, covered and acknowledged terminal session can be replaced; its snapshots, operations, receipts and conflicts are archived in the same file, and terminal markers remain to reject replay.

STEEL-9 owns actual joining/ack scheduling and WatchConnectivity exchange. Existing prepare/start/measurement transport is unchanged. There are no new Watch screens or Watch-created workouts.

## Phone writer inventory and rest recovery

- `CurrentWorkoutView`: active workout title/comment drafts and exercise addition/removal/order use `WorkoutCommandWriter`.
- `WorkoutExerciseDetailView`: result and metadata draft submission, active set addition/removal and exercise comments use the same boundary. Editing captures a base version; it follows only contiguous known local commits that leave the selected result intact and cannot silently rebase onto a concurrent remote change. Failed submission keeps the draft and selection. Leaving or changing selection discards unsubmitted set drafts.
- `WorkoutSetEditor`: weight/reps, tag, RPE and comment bind to a local value draft, never directly to managed fields.
- `EditCurrentWorkoutTimeView`: active start/end DatePicker, automatic tracking and reset use a validated time command; direct managed-object time bindings are removed. The command validates finite ordered dates and preserves active-workout status.
- `RestTimerStore` / `RestTimerView`: pair updates use one absolute-rest command; committed receipts only project to UserDefaults and effects. Startup/foreground restores the durable pair, including expired intervals and explicit cancellation. Stale displayed rest cannot overwrite a newer durable interval.
- `WorkoutDetailView` delegates active workouts to CurrentWorkoutView; its direct history date/order edits remain historical. Start/copy construct the original graph before shared identity exists. Finish/cancel/pruning remain the existing phone domain flow until STEEL-13.
- Existing phone WatchConnectivity receives preparation status only; future received mutations must call this store, never write managed fields directly.

## Migration and backup compatibility

Historical models/mappings remain intact. v5 adds session/operation records, v6 adds durable phase. Legacy v1–v3 stores migrate via the existing explicit mappings to v4, then inferred migration to current; additive v4/v5 sources migrate directly. Tests cover UUIDs, ordering, nil values, metadata and retry of the first-slice v5 encoded operations/receipts. Unknown models are rejected, never erased.

Backup stays version 3 and excludes session/operation/transport state and active workouts. Restore atomically clears metadata belonging to replaced history while preserving the current workout's identity and receipts. Optional `weightWasNil` / `repetitionsWereNil` markers retain nil versus zero while leaving legacy numeric scalar fields readable by older decoders. Existing JSON/backup fixtures remain readable. Backup restore cannot recreate an agreed channel to an old device.

## Verification

92 XCTest tests passed, including both durable stores across restart/out-of-order delivery/lost receipts, deleted-target conflicts, sequential offline edits, terminal safeguards, UI writer/rest recovery, migrations v1–v5 and backup/JSON roundtrips. The production-app XCUITest passed workout start-time reset and rest start/increase/cancel while a set draft is open, completion, correction without progression, finishing and persisted history after relaunch. WatchIron builds passed Debug and Release with pinned packages and ad-hoc signing. Localization/catalog validation and git diff checks passed. See the implementation plan for result-bundle paths and the requirements checklist.
