# Usage & development

[Back to F Jira](../README.md)

A native macOS client for on-premises Jira, written in Swift and SwiftUI.

## Connection

Enter your HTTPS Jira base URL, including a context path such as `/jira` if used,
and a personal access token created in your Jira profile. F Jira verifies it with
read-only requests to `/rest/api/2/myself` and `/rest/api/2/serverInfo`.
Browser SSO and password authentication are not supported yet.

The token is stored in macOS Keychain. Successful account and server responses
are cached in SQLite under `~/Library/Application Support/fjira/cache.sqlite`,
isolated by server and account. Restarting the app shows the saved account
without requiring a network connection. Use **Check connection** to verify it again.
**Log out** removes the active token and connection selection but preserves cached data.
No tokens are written to preferences or the database.
The account button at the bottom of the sidebar shows your Jira avatar once
downloaded and keeps it available offline using the same SQLite image cache as
comment avatars.

## Project and issue browsing

The project button in the sidebar footer shows the selected project's name, key,
and image. Click it to search and switch projects or refresh the project list.
Project responses and images are cached for offline use. The sidebar opens on **Dashboard**, with **Issues** and **Boards** under **Browse**,
with the project and account controls pinned at the bottom. Native window controls
sit above the sidebar, while the issue area extends to the top of the window.
Use the native toggle at the top of the sidebar to hide or show it.
Type ordinary words, such as `login timeout`, to search issue titles and descriptions,
or paste JQL such as `assignee = currentUser() ORDER BY priority DESC` into the same box.
F Jira detects JQL operators automatically and always restricts results to the selected project.
For ambiguous inputs, `text:` forces a text search and `jql:` forces JQL.
An empty search shows all issues, ordered by updated date and key.
Text searches match words in either the title or description using
[Jira's text-search rules](https://confluence.atlassian.com/jirasoftwareserver101/search-syntax-for-text-fields-1455427017.html).
Punctuation is escaped and words are case-insensitive. Search uses Jira's read-only
`POST /rest/api/2/search` endpoint.

Results are downloaded in pages of up to 50 issues. **Load more** follows the
server's actual page size. Table headers sort downloaded rows; JQL ordering
controls the complete result set. Status sorting follows New → Backlog → Analysis →
Developing → Reviewing → Ready for testing → Testing → Ready to release → Done.
`In Progress`/`Developing`, `Review`/`Reviewing`, and
`Ready to release`/`Ready for release` share their respective stages. Unrecognized statuses follow their Jira category, then name: To Do statuses after
Backlog, In Progress statuses before Done, and completed statuses after Done.
Statuses without a category follow those; missing statuses are last. Descending
sorting reverses this order. This local policy also works with downloaded data;
it does not infer a server workflow or alter JQL ordering. Each title is preceded by its Jira task-type icon,
with the type name available on hover. Assignee names have circular profile images,
and priorities show their Jira icons. Images are loaded once per URL and reused
across rows and issue details; saved results include cached images on their first
render. Select a row to copy its key or open it in Jira.

Every successful search is available in **Downloaded searches**, with its original
order, fetched pages, total count, and timestamp. Restarting restores the selected
project and query from SQLite. Offline, cached results remain available; new searches
and additional pages require Jira. Failed requests preserve cached data.
Refreshing the first page replaces the current result list and invalidates older
pagination, while downloaded issue responses remain cached for later use.
Projects, search results, and selections are isolated by instance and account.
The browsing migration preserves existing connections and tokens.

## Dashboard

Dashboard is the home page for the selected project. **Current Issues** shows open
issues other than New or Backlog where you are either **Assignee or Implementer**, so handing a task to a
tester keeps it in your list. Implementer is discovered from Jira's custom fields.
**Up next** uses the same ownership rule and includes New, Backlog, and Jira's To Do status category.
**Recently done** shows your Done issues resolved in the last 14 days.
Each section downloads up to 50 issues; **View all** opens its query in Issues,
where you can fetch further pages.

**Tasks completed per week** counts your Done issues by resolution week.
The chart fits as many Monday–Sunday weeks as its width allows,
always keeping the current week at the right with a stronger bar color and a
“This week” label. Widening the window loads any missing older weeks; narrowing
it keeps that history cached and displays the most recent weeks. It uses the timezone
in your Jira profile. Statistics sit above Current Issues in the same column,
with Recently viewed and comments alongside in wide windows. Click any bar to open its
query in Issues. Counts come directly from Jira, so they are not capped at 50
downloaded issues. They use current Assignee/Implementer ownership and current
Done status, rather than historical ownership or every past completion event.
The statistics and their query responses are cached per account and project;
a failed refresh preserves them. Older offline snapshots show their week instead
of presenting an old count as this week's result.

**Recently viewed** remembers the last 20 issues opened in each project and shows
the six latest. **New comments** shows up to 20 recent comments from the last seven
days, with a switch between your issues and the entire project. It scans recently
updated issues in batches of up to 150 per refresh. On busy projects, **Find more
recent activity** continues the scan. This is an activity feed, not an unread count.
Click a comment to open its issue's Comments tab.

Dashboard snapshots, comments, and visits are cached per server, account, and
project. Downloaded content appears before network refreshes and stays visible
if Jira is unavailable. Dashboard queries do not fill Downloaded searches.
Cmd+R refreshes Dashboard when no issue is open.

## Issue details

Click an issue row to open its details. When the list area is at least 940 points
wide, details appear alongside it in a resizable pane. Drag the divider to widen
the details up to the available space, leaving at least 500 points for the list
or board. In narrower windows, details open in a sheet. Resizing transfers the same issue between these presentations.
Use the close button to return to the list.

The viewer includes metadata, formatted description and comments, labels,
components, fix versions, subtasks, issue links, and attachment metadata.
Comments and History share a tabbed activity container below the issue content.
History loads on demand using Jira Server/Data Center's
[`expand=changelog` API](https://support.atlassian.com/jira/kb/how-to-analyze-the-history-or-changelog-of-an-issue-in-jira/),
shows authors, timestamps, and old/new field values newest first, and displays
50 changes at a time. Downloaded history and author avatars remain available
offline and survive issue refreshes. Failed history updates keep the cached
entries and offer Retry. If Jira returns only part of a history, the viewer says
so and links to the web issue. Tab switches preserve the existing viewport;
Left/Right Arrow, Home, and End work while the tab strip has keyboard focus.
Flagged issues show a red flag in the table, board cards, and detail header; board
cards also get a pale yellow tint. Flag state is cached for offline viewing. The
search discovers the instance-specific Flagged custom field automatically, while
boards use Jira Agile’s flag value.

Statuses use tinted pills in the table and issue metadata: gray for To Do/unknown,
blue for In Progress, and green for Done, based on Jira's status category. The
status name stays visible, with matching light and dark palettes. Older cached
searches and details recover categories from their saved responses without a refresh.
**Issue Links** combines related Jira issues with external links, including merge
requests, loaded from Jira's read-only `/rest/api/2/issue/{id}/remotelink` endpoint.
External links open in your browser. Their complete responses are cached for offline
use; failed link refreshes preserve downloaded links and do not block issue content.
Related issues open in the same viewer. **Epic Link** appears in metadata when an
issue belongs to an epic, as a pill with its Epic Name and Jira color; clicking it
opens the epic in the same viewer. Names and colors are shared with board cards
and cached per account. The field
is discovered from Jira's schema, with its name used for older cached responses,
so it supports instance-specific custom-field IDs. Epic links and viewed epic
contents remain available offline. See
[Jira's custom-field metadata](https://developer.atlassian.com/server/jira/platform/jira-rest-api-examples/).
Additional comments load in pages.
Attachment files and inline images hosted outside Jira are not downloaded; open the issue
in Jira to access them. The issue content uses one bounded, scrolling HTML view. Jira-rendered HTML is
preferred; raw Jira wiki text has a fallback for headings, lists, tables, links,
and code blocks. Literal newline escapes in prose become line breaks, while code
text preserves its escapes. Extra whitespace at the start and end of descriptions
and comments is trimmed, and repeated blank lines collapse into a single break.
Spacing inside code is preserved. Components, labels, and versions use wrapping tags.
Comment headers show the author name, readable date, and an avatar or initials.
Issue metadata shows Jira's Type and Priority icons. Below Priority, Assignee,
Implementer, and Reporter appear together with compact avatars beside their names.
Implementer is discovered by its custom-field name, including in older cached
responses; an empty Implementer field shows Unassigned. These images share the offline cache with
comment avatars; static SVG icons are supported as well as raster images.
Images are also shared in memory by URL across issues. Cached details and their
image bytes are read together and published as one state, so reused icons appear
in the first render instead of being attached after the body. Older snapshots recover
Type/Priority icon URLs from their saved full response, without requiring a network
refresh. Metadata downloads
run before comment-avatar batches, and new image results are applied per batch.

Avatars and Jira inline images, including emoticons in descriptions and comments,
are fetched separately and cached in SQLite for offline reuse. Inline image URLs
resolve against the configured Jira URL, including its context path. Jira tokens
are sent only to the configured Jira origin, including after avatar redirects.
The HTML document embeds cached image bytes and does not fetch remote resources
or execute page scripts. Updating avatars or comments preserves scroll position.
Switching issues keeps the same viewport and replaces its document in one browser
update, so the previous body stays visible until the next body is available.
A different issue starts at the top; refreshing the same issue preserves its position.

Full issue responses and comment pages are cached separately from search-list
projections. Selecting an issue immediately shows any cached details, then
refreshes from Jira. The 20 most recently viewed issues and their comment avatars
also stay in memory, so reopening them shows their saved state immediately.
The refresh arrow spins while issue details load; cached content stays visible during updates. Credential lookup runs off the UI thread, so Keychain waits
do not delay rendering cached content. Failed refreshes preserve the cached view.
An issue's download date appears only as **Offline (downloaded <date>)** after an
update fails because internet connectivity is unavailable. A successful update
clears the offline status; server and authentication failures keep their own errors. Previously loaded
comments remain available during partial refreshes and are marked as older until
current pages are fetched. Changing selection cancels the old request; late
responses cannot replace the newly selected issue.

## Boards

Choose **Boards** in the sidebar and select a board associated with the current
project. Columns follow Jira's configured names, order, and status mappings.
Cards retain Jira's rank order and show the issue key, title, type, priority, and
assignee. Tasks belonging to an epic also show its name in a colored pill, using
the same palette as the clickable Epic Link in issue details. Epic names and
colors come from Jira's Agile API and are shared through the offline cache;
unknown names fall back to the summary or key until metadata is available. Query-based swimlanes use the configured section names and order,
with a collapsible header and empty sections hidden. Issues enter the first matching
swimlane; the default section catches the remaining issues. Sections share one
horizontal scroll position and stack vertically. Section titles, counts, and fold
buttons stay at the left edge while columns scroll horizontally. Each section
takes the height of its tallest column, and all columns in that section share
that height. Cards do not scroll independently: the whole board scrolls horizontally
and vertically, with native overscroll. Folding a section hides its columns.
Click a card to open the same issue detail pane used by Issues.

Kanban boards apply their configured subquery and the board's cutoff for older
completed tasks. When Kanban backlog is enabled, its separate backlog column is
excluded from the working board. Scrum boards show issues in active
sprints. A board can include issues from several projects, matching its Jira filter.
**Filter cards** searches downloaded keys and titles. The separate **Assignee** picker
filters by any person assigned to downloaded board cards, with your account marked
**Me** and **All assignees** clearing the filter. Its choices include all sections
and cached cards beyond the visible page, regardless of the current text filter.
More people appear as additional cards are downloaded. Both filters work offline;
switching boards clears the assignee selection. Board lists, configurations, issue pages,
selection, and images are cached per Jira site and account. Cached boards appear
before refreshing. Custom swimlane boards fetch the visible board once for card fields
and each original non-default lane query for membership. Cards go into the first
matching lane locally, including cards with empty fields that JQL negation could omit.
These collections use a rolling pool of up to 32 requests, request 100 records per
page, and follow the server's actual page sizes until complete. Only the board query
downloads full card fields. Membership queries request status only.
If Jira responds with HTTP 429, requests for the same server and credential share a cooldown
and honor `Retry-After`. Requests retry up to three times with exponential backoff and jitter.
Each column displays up to 50 cards initially, revealing more when you scroll to
its bottom. Custom lane collections are downloaded completely before publishing;
ungrouped boards keep fetching 50 cards per column on demand so large Done columns
do not delay small columns. Column headers show Jira's total when available;
the paging footer shows how many cards are displayed. Cached boards also start
with at most 50 cards per column. Previously downloaded cards remain available
offline, including older cards beyond the refreshed first page. Older results are
identified in the paging footer until their pages are refreshed. Filters search
all downloaded cards; use **Load more** explicitly while filtering to fetch more.
Failed refreshes preserve the previous board, and failed next-page requests can
be retried without skipping cards. The board refresh button updates both the current
board and the available board list.

While Boards is open and the app is active, the selected board refreshes automatically
on a five-second cadence. Checks never overlap; slow requests get at least a one-second
gap after completion. Failed checks back off to 10, 20, 40, then 60 seconds, with the
normal cadence restored after success. Automatic refreshes skip ongoing refreshes and
page loads, keep the displayed cards if a request fails, and do not show a toolbar spinner.
Jira's web-board `etag` check skips card queries when the board is unchanged. A changed
token triggers the public API refresh; the new token is saved only after that succeeds.
Every 60 seconds a full check refreshes configuration and membership even if the token
is unchanged. Servers without this private endpoint fall back to public API polling.
Unchanged custom-board contents also skip cache writes and presentation callbacks.
Automatic checks reuse board configuration for up to 60 seconds and do not refresh the board picker
list. Manual refresh always reloads configuration. Configuration requests run concurrently;
the edit model uses `expand=workingDaysConfig` with a full-response fallback when required
settings are absent or the projection is rejected. Switching away from Boards or making the
app inactive pauses automatic refresh and cancels any automatic refresh in progress.
Manual refresh can interrupt an automatic check and always forces a full refresh.

Jira Server's supported push option is a webhook, which requires Jira administrator
registration and an HTTP callback reachable from Jira. This desktop app uses polling;
it does not register webhooks or run a public callback service.
[Atlassian webhook documentation](https://developer.atlassian.com/server/jira/platform/webhooks/)

Issue fields are shared between board cards, search results, and full details.
The newest Jira `updated` timestamp wins, so a stale node response cannot roll a
known Done issue back to Review. Existing downloaded details also correct older
board snapshots offline. Opening a newer issue detail immediately updates its
visible card and table row. Cards moved by a local status correction appear at
the bottom of their destination column, after its existing cards. Full descriptions and comments keep their own cached
response and are not replaced by a smaller list response.

When a board page disagrees with a known status, F Jira verifies that issue with
a small direct issue request, at most once per refresh and four requests at a
time. Unchanged cards need no extra request. Failed verification keeps the newest
known revision; direct responses cannot overwrite a newer revision either.
Corrections preserve server page offsets, hide completed issues beyond the
board's cutoff, and avoid showing an exact total for an affected incomplete
column. This mitigates inconsistent Jira indexes; it cannot discover issues
omitted by the server or re-evaluate arbitrary board/swimlane JQL locally.

Cmd+R refreshes the board and board list when no issue is open, and Cmd+O opens the board in Jira.
With an issue open, those commands apply to the issue. Switching boards or views
resets issue navigation history. This version supports viewing boards; dragging
cards, editing, Jira quick filters, and grouping by epics, stories, projects, or
assignees are not implemented. Swimlane configuration and the completed-task cutoff
come from Jira's internal read-only `rapidviewconfig/editmodel.json` endpoint;
servers that restrict this endpoint show an error and retain any cached board.
The API integration uses Jira Software's read-only
[board endpoints](https://docs.atlassian.com/jira-software/REST/7.3.1/).

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

An opt-in board benchmark scrolls a 150-card fixture across four swimlanes,
with avatars, epic pills, and varied title lengths. It scrolls horizontally,
vertically, and diagonally, reporting median, p95, and maximum main-thread update times. It checks
an 8.33 ms p95 budget and requires a visible desktop. These are CPU layout/display
measurements, not measured display FPS; results vary with system load. The regular
test suite skips this benchmark. It does not measure compositor delays or presented
frames; investigate visible stutter with an Animation Hitches trace and a real-board
comparison even when this CPU benchmark passes. Board cards flatten their artwork
into a drawing group to reduce layer-compositing work during scrolling, while
keeping buttons, accessibility, and context menus interactive.

```sh
FJIRA_SCROLL_BENCHMARK=1 swift test --package-path Packages/FjiraCore --filter BoardCanvasTests/testBoardScrollFrameBudget
```

The original logo is in `artwork/F Jira.png`. The rounded macOS icon with transparent
corners is in `artwork/F Jira App Icon.png`. Run `python3 scripts/generate-app-icons.py`
to regenerate the macOS app-icon catalog, standalone iconset, and `artwork/F Jira.icns`.
The built application is `build/Build/Products/Debug/F Jira.app`.

For a persistent development entry in Applications, run this once from the repository root:

```sh
mkdir -p "$HOME/Applications"
ln -s "$PWD/build/Build/Products/Debug/F Jira.app" "$HOME/Applications/F Jira.app"
```

This link opens the build directly, so rebuilding with the command above updates
it automatically. Quit and reopen F Jira to run a new build. Keep the checkout at
its current path; after cleaning the build directory, rebuild before launching.

Keyboard commands are defined in `FjiraUI/JiraCommands.swift`. Cmd+O opens the
current issue in Jira; Cmd+R refreshes the open issue or reruns the search when
no issue is open. Cmd+Return runs the search. Cmd+B toggles the sidebar. Cmd+W
closes the current issue, or closes the window when no issue is open. Close lives
in the File menu to replace the system Cmd+W binding; other shortcuts live in the
Jira menu. Buttons share their actions, availability, and shortcut tooltips through
`JiraCommandContext`. Each browser window supplies its context with
`focusedSceneValue`, so commands work from the table, search field, and issue
body and are disabled outside the browser. To add a command, add its identity
and presentation to `JiraCommand` and provide its action in the window context.

Back and Forward use a native navigation control in the window toolbar, to the
left of Issues, with Cmd+Left Arrow and Cmd+Right Arrow shortcuts. macOS supplies
the toolbar glass appearance.
They revisit issues opened from the table, Epic links, and issue links, including
returning to the list. Opening a new destination after Back clears the forward
branch; refreshes do not add visits. History holds up to 100 destinations for the
current project/search and resets when that context changes or the account stops.
Previously viewed details and images reuse the same memory and disk cache.
