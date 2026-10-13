# fjira

A native macOS client for on-premises Jira, written in Swift and SwiftUI.

## Connection

Enter your HTTPS Jira base URL, including a context path such as `/jira` if used,
and a personal access token created in your Jira profile. fjira verifies it with
read-only requests to `/rest/api/2/myself` and `/rest/api/2/serverInfo`.
Browser SSO and password authentication are not supported yet.

The token is stored in macOS Keychain. Successful account and server responses
are cached in SQLite under `~/Library/Application Support/fjira/cache.sqlite`,
isolated by server and account. Restarting the app shows the saved account
without requiring a network connection. Use **Check connection** to verify it again.
**Log out** removes the active token and connection selection but preserves cached data.
No tokens are written to preferences or the database.
The top-right account button shows your Jira avatar once downloaded and keeps it
available offline using the same SQLite image cache as comment avatars.

## Project and issue browsing

The top-left project button shows the selected project's name and image. Click it
to search and switch projects or refresh the project list. Project responses and
images are cached for offline use. The sidebar contains app views, currently **Issues**.
Select a project to run a JQL filter; fjira always adds the project restriction.
An empty filter shows all issues, ordered by updated date and key. You can supply
an `ORDER BY` clause, for example `assignee = currentUser() ORDER BY priority DESC`.
Search uses Jira's read-only `POST /rest/api/2/search` endpoint.

Results are downloaded in pages of up to 50 issues. **Load more** follows the
server's actual page size. Table headers sort downloaded rows; JQL ordering
controls the complete result set. Select a row to copy its key or open it in Jira.

Every successful search is available in **Downloaded searches**, with its original
order, fetched pages, total count, and timestamp. Restarting restores the selected
project and query from SQLite. Offline, cached results remain available; new JQL
queries and additional pages require Jira. Failed requests preserve cached data.
Refreshing the first page replaces the current result list and invalidates older
pagination, while downloaded issue responses remain cached for later use.
Projects, search results, and selections are isolated by instance and account.
The browsing migration preserves existing connections and tokens.

## Issue details

Click an issue row to open its details. When the list area is at least 940 points
wide, details appear alongside it in a resizable pane. In narrower windows, they
open in a sheet. Resizing transfers the same issue between these presentations.
Use the close button to return to the list.

The viewer includes metadata, formatted description and comments, labels,
components, fix versions, subtasks, issue links, and attachment metadata.
Statuses use tinted pills in the table and issue metadata: gray for To Do/unknown,
blue for In Progress, and green for Done, based on Jira's status category. The
status name stays visible, with matching light and dark palettes. Older cached
searches and details recover categories from their saved responses without a refresh.
**Issue Links** combines related Jira issues with external links, including merge
requests, loaded from Jira's read-only `/rest/api/2/issue/{id}/remotelink` endpoint.
External links open in your browser. Their complete responses are cached for offline
use; failed link refreshes preserve downloaded links and do not block issue content.
Related issues open in the same viewer. Additional comments load in pages.
Attachment files and remote inline images are not downloaded yet; open the issue
in Jira to access them. The issue content uses one bounded, scrolling HTML view. Jira-rendered HTML is
preferred; raw Jira wiki text has a fallback for headings, lists, tables, links,
and code blocks. Literal newline escapes in prose become line breaks, while code
text preserves its escapes. Components, labels, and versions use wrapping tags.
Comment headers show the author name, readable date, and an avatar or initials.
Issue metadata shows Jira's Type and Priority icons, plus compact Assignee and
Reporter avatars beside their names. These images share the offline cache with
comment avatars; static SVG icons are supported as well as raster images.
Images are also shared in memory by URL across issues. Cached details and their
image bytes are read together and published as one state, so reused icons appear
in the first render instead of being attached after the body. Older snapshots recover
Type/Priority icon URLs from their saved full response, without requiring a network
refresh. Metadata downloads
run before comment-avatar batches, and new image results are applied per batch.

Avatars are fetched separately and cached in SQLite for offline reuse. Jira tokens
are sent only to the configured Jira origin, including after avatar redirects.
The HTML document embeds cached avatar bytes and does not fetch remote resources
or execute page scripts. Updating avatars or comments preserves scroll position.
Switching issues keeps the same viewport and replaces its document in one browser
update, so the previous body stays visible until the next body is available.
A different issue starts at the top; refreshing the same issue preserves its position.

Full issue responses and comment pages are cached separately from search-list
projections. Selecting an issue immediately shows any cached details, then
refreshes from Jira. The 20 most recently viewed issues and their comment avatars
also stay in memory, so reopening them shows their saved state immediately.
The loading indicator appears only when full details are unavailable; cached issues
refresh quietly in the background. Credential lookup runs off the UI thread, so Keychain waits
do not delay rendering cached content. Failed refreshes preserve the cached view.
An issue's download date appears only as **Offline (downloaded <date>)** after an
update fails because internet connectivity is unavailable. A successful update
clears the offline status; server and authentication failures keep their own errors. Previously loaded
comments remain available during partial refreshes and are marked as older until
current pages are fetched. Changing selection cancels the old request; late
responses cannot replace the newly selected issue.

## Development

Requires macOS 14 or later and Xcode with the Swift 6 toolchain.
Open `fjira.xcodeproj`, select the `fjira` scheme, and run on My Mac.
The local package contains `FjiraCore` for API/cache behavior and `FjiraUI` for the
issue viewer. Its tests include an actual AppKit/WebKit viewport check with fixture
data; running tests briefly opens a test window.
HTML fragment builders need explicit `String` result types. GRDB's interpolation
overloads can otherwise infer `SQL` fragments and render their debug descriptions
instead of HTML. The rendering regressions check for this failure.

```sh
xcodebuild -project fjira.xcodeproj -scheme fjira -configuration Debug -destination 'platform=macOS' -derivedDataPath build build
swift test --package-path Packages/FjiraCore
```
