# Architecture

## System boundary

```text
+--------------------------+
| HITMAN WOA / Glacier 2   |
+------------+-------------+
             |
       native ABI/hooks
             |
+------------v-------------+
| Glacier Adapter          |
| ZHMModSDK-derived/native |
+------------+-------------+
             |
     semantic wire protocol
             |
+------------v-------------+
| Glacier Relay / OTP      |
|                          |
| MissionSession           |
| PlayerSession            |
| World State              |
| Event Bus                |
| Telemetry                |
| Recorder                 |
| Replication              |
+-----+-----------+--------+
      |           |
      v           v
 LiveView       Other
 Console       Clients
```

## Native adapter responsibility

The adapter is the anti-corruption layer around Glacier. It may know pointers, vtables, reconstructed C++ classes, hook addresses, engine update callbacks, and version-specific details. Nothing above the adapter may rely on those representations.

It translates engine observations into stable messages such as:

```text
mission.started
player.transform
player.disguise_changed
actor.pacified
actor.killed
item.picked_up
item.dropped
door.state_changed
camera.destroyed
objective.completed
```

The reverse channel applies commands such as:

```text
remote_player.set_transform
remote_player.apply_input
actor.set_state
door.set_state
item.set_owner
world.apply_snapshot
```

Exact names and schemas remain research work.

## OTP responsibility

OTP owns higher-level meaning and coordination: session lifecycle, player identity, authority, canonical durable facts, event fan-out, analytics, persistence, reconnection, replication policy, and observability.

A likely supervision shape:

```text
GlacierRelay.Supervisor
|
+-- ConnectionSupervisor
+-- MissionSupervisor
|   +-- MissionSession
|       +-- PlayerSession(s)
|       +-- WorldState
|       +-- Telemetry
|       +-- Recorder
|       +-- Replication
+-- WebEndpoint
```

This is a hypothesis until traffic characteristics are measured; processes should represent failure/lifecycle boundaries, not every entity by default.

## Two classes of state

**Continuous state:** transforms, velocity, aim, animation and similar rapidly changing information. This likely needs snapshots/deltas, interpolation, loss tolerance, and bounded update rates.

**Semantic state:** death, pacification, item ownership, doors, cameras, disguises, objectives, discovered bodies and other meaningful transitions. This is naturally event-oriented and often requires stronger delivery/ordering semantics.

Do not force both classes through identical replication policies.

## Failure boundary

The preferred topology is out-of-process:

```text
HITMAN.exe + native adapter <---- IPC/network ----> BEAM
```

A bad native pointer may crash HITMAN without killing the BEAM. A BEAM restart can be treated as a reconnectable service failure. Avoid placing unsafe Glacier manipulation inside a BEAM NIF unless future evidence strongly justifies it.

## Peacock boundary

Peacock emulates IOI-facing services. Glacier Relay coordinates runtime observations and commands. They solve different problems. Compatibility may become useful later, but Peacock is not required for the observer/recorder/controller/multiplayer research path.
