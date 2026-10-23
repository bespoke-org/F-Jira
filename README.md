<p align="center">
  <img src="artwork/F%20Jira%20App%20Icon.png" width="128" height="128" alt="F Jira app icon">
</p>

<div align="center">
  <h1 align="center" style="text-align: center;">F Jira</h1>
</div>

<p align="center">Your Jira, on your Mac.</p>

<p align="center">A native macOS client for Jira Server and Data Center.</p>

Browse issues, follow boards as they update, and catch up on your work from the dashboard. Downloaded content stays available offline.

## Try it

Requires **macOS 14+** and **Xcode 26+**.

```sh
xcodebuild -project fjira.xcodeproj -scheme fjira -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build build
open "build/Build/Products/Debug/F Jira.app"
```

Connect with your Jira URL and a personal access token. Tokens are stored in macOS Keychain.

Built with Swift, SwiftUI, and AppKit.

[Usage & development](docs/guide.md)
