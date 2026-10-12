# VPN plugin

Local macOS Cisco Secure Client controls. Uses the installed `/opt/cisco/secureclient/bin/vpn` for read-only state events, bounded status refresh and an explicit Disconnect action. Connect/Login opens the installed Cisco application so Cisco handles authentication. The plugin never requests or stores credentials, OTPs, cookies or SAML assertions.

Sleep check records timestamps, VPN state transitions, sleep/wake events, retained pane counts and ready Relay connection counts. Counts verify UI/session identities and transport readiness, not continued execution of remote jobs. Copy log exports these limited observations. Nothing forces sleep or disconnects the VPN to run a check.

Sleep suspends Relay heartbeat checks; waking clears expired heartbeat samples and probes existing protocol connections. Normal transport retry logic remains responsible for reconnects. The plugin does not alter university profiles or extend VPN sessions.

The bundled local manifest is `relay-plugin.json`; operation `vpn` requires the `network` permission. Disable/uninstall stops the observer without disconnecting Cisco. A supported Cisco SDK is still needed for fully native authentication. Full VPN sleep and roaming verification remains pending a user-operated sleep test.
