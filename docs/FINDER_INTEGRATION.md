# Finder integration: what's possible and what Forma does

macOS has **no public API** that lets a third-party app replace Finder's context menu or intercept Shift + right-click on a file. Forma modifies nothing in Finder: no code injection, SIP stays on, no private APIs. Instead it offers four supported entry points plus an opt-in way to get Shift + right-click working, and every one of them opens the same wheel.

## Mechanisms evaluated

| Mechanism | Verdict |
|---|---|
| **Finder Sync extension** (`FIFinderSync`) | Supported. It can add items to Finder's context menu for monitored folders (Forma monitors `/`). It can't change what Shift + right-click does, and it can't show custom UI in Finder. **Used** for "Convert with Forma…". |
| **Services** (`NSServices`) | Supported. "Open in Forma" appears under Services / Quick Actions for files, can be given a keyboard shortcut in Keyboard settings, and needs no permissions. **Used.** |
| **Global hotkey** (Carbon `RegisterEventHotKey`) | Supported and needs no permission. Combined with Apple Events to read Finder's selection, which needs one-time Automation consent. **Used** (⌥⌘K by default, configurable). |
| **CGEvent tap + Accessibility hit-testing** | The only supported way to react to Shift + right-click without changing Finder. An *active* tap, which can swallow the click so Finder's menu doesn't also open, needs Accessibility permission. **Used, opt-in.** |
| Input Monitoring only (listen-only tap) | Can observe the click but not stop Finder's own menu, which would leave two menus on screen. Not used. |
| `NSEvent` global monitors | See mouse events, but can't suppress them or identify the clicked item. Used only to dismiss the wheel on outside clicks. |
| Automator Quick Action | Equivalent to the Services entry and adds nothing. Not used. |
| Action extension (Finder preview pane) | Would need a UI-hosting extension just to launch the app. Not used. |

## How Shift + right-click works

1. With Accessibility granted and the toggle on, Forma installs a session event tap for right-mouse down and up events only. It reads no keystrokes and doesn't record or store events.
2. On a right-mouse-down with **only** Shift held, it hit-tests the screen point with `AXUIElementCopyElementAtPosition` and checks that the element belongs to Finder's process.
3. It identifies the **clicked** item rather than assuming it's whatever is selected:
   - first from the item's own `AXURL` or `AXFilename` attribute;
   - failing that, from the item's displayed name plus the window's folder (`AXDocument`). It also checks that folder's parents for column view and the Desktop, and matches names whose extension Finder hides.
   - The match has to be **unique** and the file has to **exist**. Folders are ignored.
4. If the clicked item is part of Finder's selection, the action applies to the whole selection, which is how Finder's own menu behaves. Otherwise it applies to the clicked item alone.
5. Once resolved, the click is swallowed, the wheel opens at the pointer, and releasing the button over a segment selects it. **If anything is uncertain, the event passes through untouched** and Finder shows its normal menu. Forma never acts on a guess.
6. AX calls time out after 250 ms, and the tap re-enables itself if macOS disables it for slowness.

**Verification status:** the resolver and the tap are implemented and compiled. They weren't exercised on the build machine because that needs Accessibility to be granted to Forma, which only you can do. Finder's AX tree is undocumented and can differ across icon, list, column and gallery views and between macOS versions; the fallbacks above exist for that reason.

## Setup

1. **Finder menu:** System Settings › General › Login Items & Extensions › Finder (or *Added Extensions*) › enable **Forma**. Then right-click a file › **Convert with Forma…**
2. **Shortcut:** select files in Finder and press **⌥⌘K**. Click **OK** when macOS asks whether Forma may control Finder. To change the shortcut: Forma › Settings › Shortcuts.
3. **Services:** right-click a file › Services (or Quick Actions) › **Open in Forma**. Optionally give it a shortcut in System Settings › Keyboard › Keyboard Shortcuts › Services.
4. **Shift + right-click:** Forma › Settings › Shortcuts › **Enable…**, then allow Forma in System Settings › Privacy & Security › Accessibility. The status updates without restarting the app.

If a permission was denied, every entry point shows a short message saying what to enable and where. **Settings › Integrations** shows the live status of each one.

## Communication between the extension and the app

The sandboxed extension sends `forma://open?paths=<base64url JSON array>` with `NSWorkspace.open`. The app checks that the paths exist and only shows the wheel for them. A link from anywhere else can do no more than open a wheel; converting still takes your click.
