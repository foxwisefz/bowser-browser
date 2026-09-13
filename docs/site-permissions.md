# Website permissions

Open **Settings → Websites**, **View → Website Permissions**, or the toolbar’s
site-permissions control. Choose a profile and site, then select Ask, Allow or
Block separately for camera and microphone. Saved apps also offer notification
permissions. The list includes only sites with saved Allow or Block decisions in
the selected profile. Returning every permission to Ask removes the site.

The toolbar indicator turns green while a tab in that window has an active or
muted camera/microphone capture session. Clicking it opens the capturing site’s
controls. Stop ends capture for the selected device on all matching tabs in that
profile. Blocking or resetting a device also stops matching capture. Reset This
Site restores Ask for the selected origin; Reset All affects only the selected
profile. A Stop action does not change the saved permission.

Camera/microphone prompts offer Allow Once, Always Allow, Block and Cancel.
Always Allow and Block persist; Allow Once does not create a saved exception.
macOS approval is separate: site-level Allow cannot override a Privacy & Security
denial. The settings pane displays the current macOS authorization status.

The native store is `site-permissions.json` in the browser or saved app’s state
directory. Its key is profile ID + exact origin (scheme/host/port) + permission.
Paths are not part of an origin. Default HTTPS ports are normalized; subdomains
and different ports do not inherit grants. HTTPS and HTTP loopback origins are
eligible for media permissions. Cross-origin requesting frames are denied.
Saved apps retain their own app-local permission store.

WebKit delegate callbacks enforce decisions natively, independently of backend
availability. Pending media prompts are cancelled when navigation starts or the
tab closes. A permission-store revision change invalidates a pending grant.
Saved-app notification prompts revalidate origin, live tab identity and store
revision after asynchronous macOS authorization. A macOS notification denial or
site Block takes precedence. Notifications remain limited to running saved apps;
this does not add browser-wide notifications or Web Push.

Management UI and prompt construction use the signed replaceable renderer and
shared presentation models. Platform callbacks, usage declarations and capture
operations belong to the native host. This initial host update needs a normal
quit/reopen. Later presentation changes can update live; new native permission
APIs or entitlements can still require a host update.

Automated checks cover origin/profile isolation, persistence, combined camera and
microphone policy, settings/reset scope, notification policy and the actual
Objective-C WebKit delegate export. They do not access real camera/microphone
hardware or request macOS device/notification approval.
