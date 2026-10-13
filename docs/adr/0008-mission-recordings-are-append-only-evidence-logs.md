# ADR 0008 — Mission recordings are append-only evidence logs replayed through the pure model

**Status:** Accepted in principle (2026-10-13; proposed the same day with the M4 design, `docs/design/M4_MISSION_RECORDER.md`), reconciled under *Limits stated at acceptance* and the design's section 16. Scope: **M4 — Mission recorder only.** Nothing here authorizes a command channel (M5), a native change, a change to the wire protocol, remote access, a database or a new dependency. The architectural decision accepted: **a recording is a local append-only evidence log, not a second gameplay model.**

## Limits stated at acceptance

- **Durability is what was synced.** Only a successful `datasync` moves the durable boundary; a successful write is not durability. A kill, VM crash or power loss loses an unverifiable tail of unknown size; `flush_ms` bounds nothing when the writer is stalled or degraded. Recovery can verify which complete lines exist, not which were synced.
- **The overload policy is soft.** Session-to-recorder delivery is asynchronous and unacknowledged; the mailbox is measured only when the recorder runs its loop and is unbounded during a stalled write. Discarded ranges are reported exactly because every record carries its session number; no lossless behaviour under arbitrary load is claimed.
- **A clean close is a protocol, not a side effect.** Success is reported only after the boundary, the drain, the flush, the sync, the footer, the hashes and the marker; otherwise the recording stays explicitly unclosed. `terminate/2` is one caller of it and is not sufficient alone; connection closes caused by the shutdown itself fall after the boundary and are not recorded.
- **A restarted recorder recovers the durable boundary, not the lost records.** It never appends to the unverified previous segment; a detected hole's end is known only when a later record establishes it; the cause is recorded only when directly known, otherwise `unknown`. A new node lifetime is a new recording; counters never continue across lifetimes.
- **Completeness is recorder-level and scoped.** A finalized recording establishes that the recorder wrote everything the session issued between its boundaries; it never establishes complete Glacier observation. Native queue drops, Relay sequence gaps, recorder-side missing evidence and unclean tails are four different facts; the recorder cannot show native drops were zero without the native evidence, and the replay reader must carry every one of these limits forward.

## Context

M3 closed with an OTP-owned semantic model (`Lifecycle.Instance` per adapter instance, held by `MissionSession`), a pure report over it, and a read-only projection for the dashboard (ADR 0007). Nothing persists: a node stop loses everything BEAM received, and the only durable accounts of a run are the native log and the RPC dumps taken by hand (`final_state.exs`, `beam-events.ndjson`). M2 section 52.6 recorded that an envelope-only replay cannot distinguish "no connection was ever observed" from "transport evidence was not recorded", and that future recordings must persist transport evidence beside envelopes. The session's notification carries the envelope but not the time BEAM received it, and the native sink drops envelopes while disconnected with the sequence advancing, so three different kinds of loss exist (native queue drops, Relay sequence gaps, and whatever a recorder itself fails to write) and none may be confused with another.

## Decision

1. **A recording is an append-only log of what BEAM received, nothing more.** Each record is one of: a header, a connection opened / identified / closed, a validated envelope as the wire delivered it (value-exact JSON) with its BEAM receipt time, a recorder gap, a recorder state change, a footer. No attempt, pairing, disposition, standing, count or report is ever written; those are derived at replay by the same pure model that derives them live.
2. **The recorder is outside the ingestion path, in the session's order.** `MissionSession` emits one record per evidence item to a dedicated recorder process at the point where it notifies subscribers today, with a session-assigned record number and connection number; ingestion gains one `send` per record and never waits for disk. The recorder batches, writes and syncs on its own timer.
3. **Receipt time is evidence.** The record carries the `received_at` the connection stamped and the session holds; a recorder never restamps it and never presents its own clock as the receipt time.
4. **Transport evidence is recorded beside semantic envelopes**, and a recording states whether it carries transport evidence at all, so that "never observed", "not recorded" and "lost" stay three different readings. A connection close never becomes a mission stop, in the recording or in the replay.
5. **Format: human-readable NDJSON segments on the Linux filesystem**, one recording per node lifetime, identified by a random id, with a header, a footer on clean close, size-based segments, a size budget that stops recording rather than deleting, and recovery at the record boundary. No database, no term storage, no new dependency for the evidence log.
6. **Replay is a function from files to values.** It folds records in record order through the pure model, reproduces the session's interpretation exactly (equivalence is tested as term equality of instances and byte-identical report text), never opens a socket, never touches the session or the game, and labels its output as a replay of a named recording.
7. **Loss classes stay apart**: native drops (native log counters, not available to the recorder), Relay sequence gaps (`Lifecycle.gaps`), recorder-side missing evidence (record-number holes with their cause when directly known) and unclean or unverifiable tails. A replay reports completeness from them separately and never claims completeness it cannot show.

## Consequences

- `MissionSession` gains an additive record subscription and two counters; `Wire.Envelope` keeps the decoded wire object; later, the session's fold is extracted into a pure module shared with the replay. Existing messages, state, read API and all M2/M3 tests stay byte-identical.
- Recordings are comparable with every existing evidence artefact (`compare.py`, fixtures, native logs) without new tooling, and a recording's envelope records can become a test fixture by extraction.
- The dashboard's `:replay` label and the recorder's `origin` label are the environment's statements; a replay of a recording is a third, distinct source label.
- Spatial data, analytics beyond the existing evidence, a dashboard mode over recordings, and remote or shared storage are separate decisions.

## Alternatives rejected

- **Write-ahead logging inside `MissionSession`**: about a millisecond of synced I/O on the ingestion process per flush, unbounded on a stalled disk; a recorder failure would become a session failure.
- **A plain subscriber with its own timestamps**: zero change, but it would present a later time as the receipt time (or invent a third one) and could not account for records missed across its restarts.
- **Recording at the connection boundary only**: preserves the receipt time but not the session's global order; equivalence would rest on a second implementation of identification and interleaving.
- **A second model or a derived store as the recording**: diverges from the session's interpretation and reopens interpretation outside the pure modules.
- **`dets`, `disk_log`, `mnesia`, term storage or an embedded database for the evidence log**: unreadable, unordered, a dependency, or no gain over `:file` for an append-only, low-rate, human-read log; a database is re-evaluated only for a cross-recording index if volumes ever justify it.
- **Per-attempt or per-instance files**: attempt boundaries are interpretation and would be fixed at write time; facts that belong to no instance (unidentified connections, cross-instance order) would have no home.
