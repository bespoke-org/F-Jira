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
**Disconnect** removes the active token and connection selection but preserves cached data.
No tokens are written to preferences or the database.

## Project and issue browsing

The project sidebar loads visible projects from Jira and caches the full response.
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

## Development

Requires macOS 14 or later and Xcode with the Swift 6 toolchain.
Open `fjira.xcodeproj`, select the `fjira` scheme, and run on My Mac.
The local `FjiraCore` package contains the API client and GRDB-backed SQLite cache.

```sh
xcodebuild -project fjira.xcodeproj -scheme fjira -configuration Debug -destination 'platform=macOS' -derivedDataPath build build
swift test --package-path Packages/FjiraCore
```
