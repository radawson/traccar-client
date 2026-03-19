# QA Smoke-Test Checklist

This checklist validates command transport logging, fallback behavior, and the updated log viewer placement.

## Preconditions

- Server is reachable and command transport is configured.
- A test device is enrolled and online.
- Client app is installed with Advanced settings available.

## 1) Command Lifecycle Logging (`commandId` correlation)

1. Send a `positionSingle` command to the device.
2. Open the client log viewer from Advanced settings.
3. Confirm the same `commandId` appears through:
   - `command_received`
   - `command_execute_start`
   - `command_execute_success`
   - `command_ack_sent`

If command execution fails, confirm:

- `command_execute_failed`
- `command_nack_sent`

## 2) WebSocket Reconnect Diagnostics

1. With WebSocket transport active, disable network connectivity.
2. Wait for disconnect and reconnect scheduling.
3. Re-enable network connectivity.
4. Confirm reconnect diagnostics and transport recovery:
   - reconnect reason contains `reconnect_`
   - command transport returns to websocket once connected

## 3) FCM Fallback Path

1. In Advanced settings, disable WebSocket transport (or break WebSocket URL).
2. Keep fallback enabled for FCM-capable devices.
3. Trigger a command.
4. Confirm logs include:
   - `command_received` with `source: fcm`
   - command lifecycle events with matching `commandId` where available

## 4) Plugin (GMS) Path Logs

On Android with Play Services available:

1. Start tracking.
2. Trigger movement and stop.
3. Confirm logs include plugin-path events:
   - `geolocation_init`
   - `geolocation_enabled_change`
   - `geolocation_motion_change`

## 5) Fallback (No GMS) Path Logs

On Android without Play Services:

1. Start tracking.
2. Confirm fallback service activity logs:
   - `fallback_geolocation_init`
   - `fallback_geolocation_start`
   - `fallback_geolocation_stop` (after stopping tracking)

## 6) UI Placement Check (Log Viewer)

1. Open the main screen and confirm no `Show status` button is present.
2. Open Settings and enable Advanced.
3. Confirm a log viewer entry is present in Advanced settings.
4. Tap it and verify `StatusScreen` opens.
