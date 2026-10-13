# fjira

A native macOS client for on-premises Jira, written in Swift and SwiftUI.
The initial application opens a single empty window.

## Development

Requires macOS 14 or later and Xcode with the Swift 6 toolchain.
Open `fjira.xcodeproj`, select the `fjira` scheme, and run on My Mac.

Build from the command line:

```sh
xcodebuild -project fjira.xcodeproj -scheme fjira -configuration Debug -derivedDataPath build build
```
