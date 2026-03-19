# GrapheneOS 15 Command Transport Test Matrix

This matrix validates WebSocket-primary command transport with optional FCM fallback.

## Test Environments

- Device A: GrapheneOS 15 with sandboxed Google Play Services
- Device B: GrapheneOS 15 without Google Play Services
- Server: Traccar main with WebSocket command endpoint enabled

## Functional Scenarios


| Scenario                                     | Device A (Play) | Device B (No Play) | Expected                                                     |
| -------------------------------------------- | --------------- | ------------------ | ------------------------------------------------------------ |
| WebSocket connected, FCM fallback enabled    | Yes             | Yes                | `active command transport = websocket`, commands execute     |
| WebSocket unavailable, FCM fallback enabled  | Yes             | N/A                | `active command transport = fcm` on Device A                 |
| WebSocket unavailable, FCM fallback disabled | Yes             | Yes                | HTTPS location upload continues, no remote command execution |
| WebSocket reconnect after network loss       | Yes             | Yes                | reconnect reason logged, transport returns to `websocket`    |
| Duplicate `commandId` replay                 | Yes             | Yes                | command executed once, duplicate acknowledged                |

For each command scenario, verify correlated diagnostic sequence using the same `commandId`:

- `command_received`
- `command_execute_start`
- one of `command_execute_success` or `command_execute_failed`
- one of `command_ack_sent` or `command_nack_sent`

## iOS Scenarios

| Scenario | Expected |
|---|---|
| Auto mode with Firebase available | `active command transport = fcm` |
| Auto mode with Firebase unavailable/failed init + WebSocket configured | fallback to `websocket` |
| WebSocket only mode | `websocket` only, no FCM command execution |
| FCM only mode | `fcm` only, WebSocket ignored |
| Disabled mode | no remote commands, HTTPS location upload still works |


## Lifecycle Scenarios

- App foreground start/stop
- App background (screen off)
- App process kill and relaunch
- Device reboot

Expected result for each:

- Transport status recovers automatically.
- No crash loops.
- Last command timestamp and last reconnect reason update in diagnostics UI.

## Permission and Policy Scenarios

- Location permission changed from "Allow all the time" to "While in use"
- Notification permission denied
- Battery optimization enabled again after being disabled

Expected result:

- Tracking start failures are surfaced clearly to user.
- Command transport state remains visible even when command execution fails.

## Troubleshooting Checklist

When a scenario fails:

1. Confirm websocket session/auth state is healthy.
2. Locate `command_received` and ensure `commandId` is present.
3. Trace lifecycle events for the same `commandId` through execute and ack/nack.
4. If `command_execute_failed` appears, capture `error` and validate permissions/policy state.
5. If websocket command events are missing, test fallback path behavior according to configured mode.

## Rollout Gates

Promote WebSocket primary rollout only after all gates pass:

1. Command delivery success rate >= 99% over 7-day test window.
2. Median command latency <= 5 seconds on stable network.
3. No regression in HTTPS location upload reliability.
4. Zero crash regressions attributable to command transport.
5. GrapheneOS no-Play profile verified to run commands via WebSocket without FCM.

## Dependency Maintenance Scope

- `npm audit` findings are tracked separately from this matrix and should not block transport-behavior validation unless they directly affect runtime behavior under test.

