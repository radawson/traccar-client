# WebSocket Command Contract

This document defines the command channel between Traccar Client and Traccar Server for remote commands without Google Play Services.

## Version

- Protocol: `traccar-client-command-v1`
- Transport: secure WebSocket (`wss://`)

## Connection and Authentication

Client opens a WebSocket connection to a configured URL:

`wss://<server>/api/socket/commands`

Immediately after connect, client sends an auth frame:

```json
{
  "type": "auth",
  "protocol": "traccar-client-command-v1",
  "deviceId": "0e2f0b2e-5e24-4e7d-a5b7-4f6e7fb14a9d",
  "timestamp": "2026-03-18T20:15:00.000Z",
  "auth": {
    "token": "<opaque-token>"
  }
}
```

Server responds with either:

```json
{ "type": "auth_ok", "sessionId": "abc123", "timestamp": "2026-03-18T20:15:00.100Z" }
```

or:

```json
{
  "type": "auth_error",
  "code": "invalid_token",
  "message": "Token is invalid for device",
  "timestamp": "2026-03-18T20:15:00.100Z"
}
```

## Command Frame

Server pushes command frames:

```json
{
  "type": "command",
  "protocol": "traccar-client-command-v1",
  "deviceId": "0e2f0b2e-5e24-4e7d-a5b7-4f6e7fb14a9d",
  "commandId": "9fd5642d-4f27-495f-aaf8-1297d3f9b9e7",
  "command": "positionSingle",
  "timestamp": "2026-03-18T20:15:03.000Z",
  "payload": {}
}
```

Allowed command values:

- `positionSingle`
- `positionPeriodic`
- `positionStop`
- `factoryReset`

Unknown commands must be rejected with `nack`.

## Ack and Nack Frames

Client responds for each command with either `ack` or `nack`.

Ack:

```json
{
  "type": "ack",
  "protocol": "traccar-client-command-v1",
  "deviceId": "0e2f0b2e-5e24-4e7d-a5b7-4f6e7fb14a9d",
  "commandId": "9fd5642d-4f27-495f-aaf8-1297d3f9b9e7",
  "timestamp": "2026-03-18T20:15:04.120Z"
}
```

Nack:

```json
{
  "type": "nack",
  "protocol": "traccar-client-command-v1",
  "deviceId": "0e2f0b2e-5e24-4e7d-a5b7-4f6e7fb14a9d",
  "commandId": "9fd5642d-4f27-495f-aaf8-1297d3f9b9e7",
  "timestamp": "2026-03-18T20:15:04.120Z",
  "error": {
    "code": "execution_failed",
    "message": "Location permission denied"
  }
}
```

## Heartbeat

To keep idle sessions alive:

- Client sends `ping` every 60 seconds.
- Server may send `ping`; client must answer `pong`.
- If no message is exchanged for 180 seconds, either side may close the socket.

Client ping:

```json
{
  "type": "ping",
  "protocol": "traccar-client-command-v1",
  "deviceId": "0e2f0b2e-5e24-4e7d-a5b7-4f6e7fb14a9d",
  "timestamp": "2026-03-18T20:16:00.000Z"
}
```

## Delivery Semantics

- At-least-once delivery.
- Server can resend unacked commands after reconnect.
- Client must treat `commandId` as idempotency key and ignore duplicate command IDs that were already acknowledged recently.
- Recommended replay retention: 10 minutes.

## Reconnect Strategy

Client reconnects with exponential backoff:

- initial delay: 2s
- max delay: 60s
- random jitter: up to +20%

Reconnect reason should be logged locally and to Crashlytics.

## Transport Diagnostic Events

Client transport logging uses standardized event names with optional JSON context:

- `command_received` (`source`, `command`, `commandId`)
- `command_execute_start` (`source`, `command`, `commandId`)
- `command_execute_success` (`source`, `command`, `commandId`)
- `command_execute_failed` (`source`, `command`, `commandId`, `error`)
- `command_ack_sent` (`source`, `commandId`)
- `command_nack_sent` (`source`, `commandId`, `code`)
- `command_duplicate_acked` (`source`, `command`, `commandId`)
- `command_error` (`error`) for transport-level failures

Tracking services also emit transport diagnostics, including:

- `geolocation_init`, `geolocation_enabled_change`, `geolocation_motion_change`
- `fallback_geolocation_init`, `fallback_geolocation_start`, `fallback_geolocation_stop`
- `notification_token_fetch_failed`, `notification_token_upload_failed`

All events are emitted to local diagnostics logs and mirrored to Crashlytics log lines.

## Troubleshooting Flow

1. Confirm `command_received` exists for a failing command and capture `commandId`.
2. Verify a matching `command_execute_start` appears with the same `commandId`.
3. Check for either:
   - `command_execute_success` followed by `command_ack_sent`, or
   - `command_execute_failed` followed by `command_nack_sent`.
4. If no command arrives, inspect reconnect-related diagnostics and websocket auth errors first.
5. If websocket is unavailable, verify fallback policy (`Auto` / `FCM only`) and transport selection.

## Error Codes

Recommended `error.code` values:

- `invalid_payload`
- `unknown_command`
- `execution_failed`
- `unauthorized`
- `internal_error`

## Fallback Behavior

- If WebSocket is unavailable, client may use FCM fallback if enabled and available.
- If neither WebSocket nor FCM is available, location uploads continue via HTTPS and remote commands are disabled.

## Out Of Scope

- `npm audit` findings are tracked as a separate dependency-maintenance stream and are not part of command transport feature fixes.
