# System WebKit push delivery probe

Tested 2026-09-13 on macOS 26.6.2 (25G83), arm64, installed WebKit
21624.5.1.11.3. Tracking: `bowser-browser-fy6e.2`.

## Result

A Developer ID-signed app with hardened runtime and no extra entitlements can
deliver a local payload through `_processPushMessage:completionHandler:` to a
real service worker after destroying its WKWebView. The worker reported zero
window clients, read the exact payload, and requested a native notification.
Passing that notification's native metadata to
`_processPersistentNotificationClick:completionHandler:` dispatched a real
`notificationclick` event to the worker.

Standard `registration.pushManager.subscribe(...)` failed with:

```text
AbortError: No connection to push daemon
```

This proves native worker dispatch and click dispatch, **not** a complete Web
Push integration. No subscription endpoint was created, no network push service
was connected, and no encrypted Web Push payload was decrypted. Subscription
provider integration remains the gate before building a production relay.

## Method and controls

`bin/check-web-push` builds `tests/web-push-probe/Probe.m` as a separate app,
signs it with a normal Developer ID identity, and runs a loopback fixture server.
Each run uses fresh randomly identified WKWebsiteDataStores and a temporary
home override. It neither launches installed Bowser nor reads its profiles.
It does not install a daemon, alter system services or claim private entitlements.

The fixture registers an actual service worker on a secure-context loopback
origin. Native private preference setters enable push/notification APIs. The
data-store delegate supplies an Allow decision for this test origin. This tests
an already-approved site, not a user gesture or permission prompt.

After the page reports readiness, the probe removes message handlers, detaches
and releases the WKWebView, closes its window, and dispatches after a delay.
Evidence is posted by the service worker itself to the loopback fixture; no
page script synthesizes the push or notificationclick events.

Two controls precede valid delivery: an unregistered scope and a different
fresh data store, each with a distinct payload. Neither control payload reaches
the worker. The other data store returns false. The unregistered scope returns
true despite delivering no event: the native completion flag must not be treated
as an end-to-end delivery acknowledgement.

The native notification delegate captures the request and invokes click dispatch
programmatically. The test does not request macOS notification permission,
display a banner, simulate a user's click, or exercise `clients.openWindow`.
It also does not prove persistence across app relaunch, worker process termination,
minimum supported macOS compatibility, or encrypted remote delivery.

## Reproduce

```sh
BOWSER_SIGN_IDENTITY='Developer ID Application: Foxwise AI FZ-LLC (V7W5LP47U9)' bin/check-web-push
```

The command prints an evidence directory containing native and worker JSONL,
stderr, signing inspection, and the isolated app. It asserts actual payload,
zero clients, notification-click evidence, and absence of control deliveries.
Its PASS line applies only to those assertions. Subscription results are printed
separately. The fixture server exits with the runner; evidence is retained.

## Next engineering question

Can we attach a Bowser subscription provider to the system WebKit PushManager
without Apple's private entitlement or replacing the engine? Investigate the
custom daemon configuration/protocol and native subscription hooks. The working
payload dispatch method is a possible receiver integration, but supplies neither
subscription creation nor a standards-compliant `PushSubscription` object.
Do not ship a page-only shim as a substitute for that integration.

Reference declarations and dictionary format:
[WKWebsiteDataStore private API](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebsiteDataStorePrivate.h),
[WebPushMessageCocoa](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/Shared/Cocoa/WebPushMessageCocoa.mm),
[data-store delegate](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/_WKWebsiteDataStoreDelegate.h).
