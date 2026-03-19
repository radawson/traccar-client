# Device Provisioning Guide

This guide covers APK delivery, device enrollment, QR configuration, and post-install verification.

## Prerequisites

- Traccar server is running and reachable.
- You have admin access to Traccar Web.
- A signed client APK is available (for example `app-release.apk`).

## 1) Upload APK to Server Override Directory

Place the APK in the server override path:

- File location: `override/downloads/traccar-client.apk`
- Public URL: `/override/downloads/traccar-client.apk`

Notes:

- Create `override/downloads/` if it does not exist.
- If the file is missing, the URL returns `404`.

## 2) Create a Device in Traccar Web

1. Go to **Settings -> Devices**.
2. Create a new device with:
   - **Name**
   - **Identifier** (must match client app identifier for the target device)
3. Save the device.

## 3) Generate Device QR Configuration

1. Open the device edit page.
2. Click **QR Code**.
3. Confirm the payload includes:
   - `id` set to the device identifier
   - WebSocket settings (`websocket_url`, `websocket_enabled`)
   - command transport settings
4. Copy or display the QR code for scanning.

## 4) Install the Client App

Use one of the following:

- Download from the devices-page APK link (`/override/downloads/traccar-client.apk`)
- Sideload via local file transfer

## 5) Scan QR in the Client

1. Open the client app.
2. Go to Settings and tap the QR scanner icon.
3. Scan the server-generated device QR code.
4. Save/apply the imported settings.

## 6) Verify Enrollment and Transport

1. Start tracking from the client.
2. In Traccar Web, confirm device status updates.
3. In client Advanced settings/log viewer, verify:
   - expected command lifecycle logs
   - active transport reflects current mode (websocket/fcm/none)
4. Send a test command and confirm correlated logs with `commandId`.
