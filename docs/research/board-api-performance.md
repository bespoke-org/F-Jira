# Board API performance

Research date: 2026-10-22. Cached server information identifies the connected deployment as Jira 8.20.7. This note separates documented behavior, code observations, and live read-only measurements. It contains no credentials, server addresses, issue contents, or customer queries.

## Findings

F Jira uses a suitable public endpoint for cards, but its request partitioning is expensive. Jira does not require a separate request for every column and swimlane. A narrower configuration request took 0.45–0.50 seconds instead of 2.20 seconds, preserving all settings the app consumes. Jira's web board request took 1.22–1.27 seconds and returned cards with their lane memberships. The current public card queries took 2.37–5.09 seconds after configuration.

The investigation also confirmed missing cards in our current swimlane filtering. Boardwide search and Jira's web board returned 72 cards; our exclusive lane queries returned 69. Using original lane queries and assigning matches locally recovered all 72 and matched every web lane. Reducing requests should include fixing this membership logic.

## Current implementation

These are code observations, not claims about Jira internals:

- `BoardReader.beginLoading` fetches public board configuration, then the private GreenHopper edit model. It waits for both before requesting cards.
- It requests the first 50 issues separately for each populated column in every swimlane. Empty results still cost a request. The concurrency ceiling is 32, with a barrier between batches.
- `Boards.boardIssues` already requests a limited field list: summary, status, assignee, priority, updated, issue type, project, flagged, and epic. It preserves the endpoint's default ordering.
- The query includes mapped statuses, active sprints for Scrum, Kanban subquery, lane membership, and the completed-card cutoff. `BoardSwimlanes` makes custom lane queries mutually exclusive by excluding preceding lanes.
- A refresh retains the old presentation until all first pages succeed. Additional pages load per cell. Cache reconciliation can make extra issue requests when responses disagree.
- `boardSwimlanes` fetches the whole `rapidviewconfig/editmodel.json` response but consumes only `swimlanesConfig`, `oldDoneIssuesCutoff`, and `isKanPlanEnabled`.

Relevant code: [BoardReader.swift](../../Packages/FjiraCore/Sources/FjiraCore/BoardReader.swift), [Boards.swift](../../Packages/FjiraCore/Sources/FjiraCore/Boards.swift), [BoardSwimlanes.swift](../../Packages/FjiraCore/Sources/FjiraCore/BoardSwimlanes.swift).

## Public card API

Atlassian documents `GET /rest/agile/1.0/board/{boardId}/issue` as a paginated board issue collection. Its optional `jql` restricts the results, `fields` selects returned fields, and `startAt`/`maxResults` control pagination. Results normally follow rank; an explicit JQL ordering takes precedence. The documented page default is 50, with a server-configured search limit. There is no requirement to query each column separately. Public configuration includes the saved filter, status-to-column mappings, and ranking field. [Jira Software REST reference](https://docs.atlassian.com/jira-software/REST/7.0.4/)

Consequently, the same public endpoint can fetch one lane across all visible columns by retaining its lane JQL and removing only the single-column restriction. Local grouping by status can preserve the relative order returned by Jira. This is an implementation proposal, not an Atlassian performance guarantee.

The server can return fewer records than requested; limits can differ by endpoint and version. `total` can change during pagination and may be omitted. Do not assume that asking for 100, 500, or 1,000 guarantees that page size. Continue based on returned pagination metadata and protect against duplicate/nonadvancing pages. [Jira Software pagination reference](https://docs.atlassian.com/jira-software/REST/9.12.0/)

The exact 8.20 platform reference also documents the configurable search cap, field selection, and read-only search using either GET or POST. POST is useful for JQL that exceeds practical URL limits. [Jira 8.20 REST reference](https://docs.atlassian.com/software/jira/docs/api/REST/8.20.0/)

## Preserve board semantics

Reducing requests must preserve these behaviors:

| Behavior | Evidence and implication |
| --- | --- |
| Kanban subquery | Jira applies an additional configurable filter to the board view. Fetching only the saved filter can include issues that the board hides. [Configuring filters](https://confluence.atlassian.com/jirasoftware/configuring-filters-1688898400.html) |
| Completed-card cutoff | The Kanban retention rule uses the last update time of issues in the Done column. It is not simply the resolution date or the status category. Keep the configured retention period when changing the fetch strategy. [Jira 7.9 release notes](https://confluence.atlassian.com/jirasoftware/jira-software-7-9-x-release-notes-946034808.html) |
| Backlog exclusion | F Jira currently removes the first column when Kanban backlog is enabled. Atlassian's internal constant identifies the Kanban backlog column position as zero. This is internal evidence, not a public REST compatibility promise. [Jira Software constants](https://docs.atlassian.com/jira-software/9.12.34/constant-values.html) |
| Lane queries | Custom lanes may contain arbitrary JQL or plugin functions. A wholesale move to local evaluation would need an equivalent query engine. Keeping one server query per lane avoids that requirement. This is an implementation constraint inferred from the current code. |
| Cell pagination | A global first page can fill with issues from one column. It does not guarantee the first 50 issues in every cell. Complete lane pagination, or an adaptive fallback for undersupplied cells, is necessary to preserve current presentation. This follows from F Jira's per-cell limits. |

### Possible missing cards from negated lane queries

The current first-match implementation assumes that negating a lane's JQL produces the complement of its matches. That assumption is not generally valid in Jira. Atlassian documents `field != value` as equivalent to `NOT field = value`; neither matches an empty field. For example, negating an assignee equality can omit unassigned issues instead of placing them in the default lane. [JQL operators reference](https://confluence.atlassian.com/jirasoftwareserver105/advanced-searching-operators-reference-1540237415.html), [Atlassian troubleshooting article](https://support.atlassian.com/jira/kb/why-my-jql-search-with-not-in-or-not-equals-operators-has-issues-missing/)

Live comparison confirmed that our added exclusions lose three cards. All three appeared in original positive lane queries, but disappeared from the union of the mutually exclusive queries. They belong to a non-default web lane, and none were unassigned. The exact nullable field responsible was not isolated; the general NOT/EMPTY problem above explains why this construction cannot safely implement set subtraction.

A verified alternative fetched the complete visible board universe and each original positive lane query, then assigned IDs to the first matching lane locally. The default lane became the universe minus assigned IDs. This recovered all 72 cards and matched all six web lanes. It preserves server evaluation of arbitrary JQL without query negation, and needs one board collection plus one per non-default lane, with additional pages as required. Matching the current per-cell implementation alone would have preserved the existing bug.

## Smaller configuration requests

Atlassian's published `RapidViewEditResource` Java documentation describes a nonempty `expand` query parameter for the edit model. An absent or empty value returns the entire result. A supplied value expands only the named sections. The readable reference is for Jira Software 9.12.1; availability and response fields on 8.20.7 must be verified. [RapidViewEditResource](https://docs.atlassian.com/jira-software/9.12.1/com/atlassian/greenhopper/web/rapid/view/RapidViewEditResource.html)

Documented expansion names are `cardLayoutField`, `detailViewFieldConfig`, `estimationStatisticConfig`, `filterConfig`, `jqlAutoComplete`, `rapidListConfig`, and `workingDaysConfig`. Swimlanes and the two flags consumed by F Jira are not expansion names in that list. [Expansion constants](https://docs.atlassian.com/jira-software/9.12.34/constant-values.html)

Live verification on the connected server succeeded with `expand=workingDaysConfig`. The three consumed fields were present and structurally identical to the full response. Two requests took 0.50 and 0.45 seconds versus 2.20 seconds for the full model. `expand=rapidListConfig` also preserved those fields but took 2.01 seconds, so response size alone does not explain the cost. Keep full-model fallback if another deployment's narrower response cannot be decoded or lacks required data. An empty `expand` will not provide this optimization.

The internal `SwimlaneResource` has a GET for one identified lane, `/swimlanes/{rapidViewId}/{id}`. Its published methods do not establish a GET that returns all swimlane configuration. Do not invent `/rapidviewconfig/swimlanes` as a replacement without server evidence. [SwimlaneResource](https://docs.atlassian.com/jira-software/10.7.2/com/atlassian/greenhopper/web/rapid/view/SwimlaneResource.html)

An internal GET `/rapidview/{id}` also exists and returns `RapidViewEntry`. Its Java reference does not establish that it contains all three configuration fields F Jira needs. It is a probe candidate, not a confirmed replacement. [RapidViewResource](https://docs.atlassian.com/jira-software/10.7.2/com/atlassian/greenhopper/web/rapid/view/RapidViewResource.html)

## The web board endpoint

Jira has an internal GET `/rest/greenhopper/1.0/xboard/work/allData.json?rapidViewId=...`. The published `WorkResource` exposes active sprint, quick filter, selected project, and `etag` query parameters. The signature alone does not establish the behavior of the `etag` parameter or whether it avoids server-side query work. [WorkResource](https://docs.atlassian.com/jira-software/10.7.2/com/atlassian/greenhopper/web/rapid/work/WorkResource.html)

Atlassian's current Data Center user documentation explicitly shows this request for inspecting active sprint or Kanban board result counts. It also warns about render and search-result limits. This confirms that the endpoint is real and used for board data; it does not make its private response schema a stable public integration contract. [Refining your backlog](https://confluence.atlassian.com/jirasoftwareserver112/refining-your-backlog-1688899326.html)

Atlassian's original public API announcement says the private Agile API can change and recommends migration to the public API. Its statement specifically covers Server P2 integrations as well as Cloud Connect. The app already depends on private GreenHopper configuration, so using the web card endpoint would extend that dependency. [Atlassian's API announcement](https://community.atlassian.com/forums/discussion/358931/jira-agile-rest-api)

A possible fast path is to decode the compact web board response, preserve lane/column memberships, and retain the public API as fallback. Live requests worked with the app's existing authentication and took 1.22 and 1.27 seconds. The response contained 72 cards, status-to-column mappings, and six lanes with issue IDs. Its fields include summary, status, assignee, priority, type, epic and flagged state, with entity lookup tables.

However, the inspected response omitted per-issue `updated` timestamps, which our shared cache uses to reconcile issue revisions. It is not a drop-in replacement. An adapter must address revision handling, all displayed fields, ordering, and `maxIssuesExceeded` or other truncation signals. A batch hydration request might recover missing fields, but its end-to-end cost has not been measured. Current documentation's limits must not be assumed to apply unchanged to 8.20.7. The optional `etag` parameter was not tested.

## Other options

- Cache configuration separately from cards with a bounded lifetime. Use cached metadata immediately for automatic refresh, then revalidate it. If the configuration changes, restart the card fetch under the new configuration. The current cache already stores the raw responses. This trades immediate detection of board-setting changes for fewer expensive configuration reads.
- Refresh the board-picker list separately from card refresh. Its completion need not control the current board's spinner.
- Replace batch barriers with a rolling pool if per-cell requests remain. Keep the existing request ceiling and shared 429 cooldown. This improves utilization but does not reduce Jira query work.
- A generic `/rest/api/2/search` query can combine a saved filter and board restrictions, or hydrate a batch of issue IDs. It will need explicit ranking and equivalent field mapping. Atlassian documents field selection and POST search for long JQL. [Jira REST examples](https://developer.atlassian.com/server/jira/platform/jira-rest-api-examples/)
- Do not assume an `updated > lastRefresh` query is a complete board delta. It can miss removals from the board, visibility changes, configuration changes, and membership effects caused by other issues or time-dependent JQL. Use periodic full membership reconciliation if incremental refresh is introduced. This is a correctness analysis, not a documented Jira delta protocol.

The public references reviewed do not establish a board change stream or a supported batch-of-independent-JQL endpoint for Jira 8.20. New Cloud enhanced board/search endpoints use different pagination and are not evidence that those capabilities exist on this Server deployment.

## Measurements

Measurements used the connected board and the app's existing authentication. No Jira records or settings were changed. The board had 10 mapped columns and 6 lanes at measurement time. Timings include HTTP and response handling, not a complete UI refresh. Requests used selected issue fields. These are small samples on a mutable live board, not latency guarantees.

| Request strategy | Requests | Observed seconds | Result |
| --- | ---: | ---: | --- |
| Public board configuration | 1 | 0.20 | 2,325 bytes |
| Full private edit model | 1 | 1.91, 2.20 | 296,825 bytes |
| Edit model with `expand=workingDaysConfig` | 1 | 0.50, 0.45 | 172,966 bytes; consumed fields identical |
| Edit model with `expand=rapidListConfig` | 1 | 2.01 | 181,044 bytes; consumed fields identical |
| Current cells, at most 32 concurrent | 60 | 5.09, 2.37 | 69 cards; every first page complete |
| Existing exclusive lane queries, all columns | 6 | 2.42, 2.27 | 70 then 69 cards; every first page complete |
| Whole visible board, public API | 1 | 3.35 | 72 cards, returned page size 100 |
| Web `xboard/work/allData.json` | 1 | 1.22, 1.27 | 72 cards; about 89 KB |

The cell/lane comparison reversed its order on the second round to reduce cache bias. The first comparison differed in one cell; the second had identical ordered IDs in every cell. Results still varied, so reducing 60 requests to 6 did not establish a proportional latency improvement. The public boardwide request was slower than six concurrent lane requests in this sample.

A separate correctness experiment fetched the universe, current exclusive queries and original positive queries concurrently, then fetched the web board. All public pages were complete. Universe size was 72, exclusive union 69, and all three missing IDs matched positive queries. Local first-match assignment matched every web lane. The combined 12-query diagnostic stage took 6.15 seconds; this is not a measurement of the proposed six-query implementation alone.

## Recommended changes

1. Request `expand=workingDaysConfig`, validate required fields, and fall back to the full edit model when necessary. This is the smallest measured improvement, saving about 1.7 seconds in the projection experiment without using stale configuration. The two metadata requests can also run concurrently because their inputs do not depend on each other's response.
2. Replace per-cell queries and arbitrary JQL negation with a board-universe query plus original non-default lane queries, then group locally by first matching lane and status. On this board that is six collections instead of 60, and it fixes the observed three missing cards. Complete pagination is necessary; use bounded concurrency and retain the shared 429 handling. Measure the final implementation before promising a latency target.
3. Prototype the web endpoint if closer parity with the web UI's roughly 1.2-second data request is needed. Its measured speed and native memberships are attractive, but the missing revision timestamps and private schema need a deliberate cache integration and fallback.

Only this research document was retained from the original investigation. Temporary live diagnostic tests and private responses were kept outside the repository after use.

## Implemented follow-up

The subsequent implementation uses positive membership queries with local assignment, smaller metadata responses, concurrent metadata fetches, a rolling concurrency limit of 32 for lane collections, and five-second automatic polling while the board is visible and the app is active. Ungrouped boards retain per-column pagination to avoid loading large Done columns in full.

Live measurements of the implementation returned 72 cards in all three runs. Combined metadata took 0.79 seconds. Full card collection took 3.90, 3.58, and 4.80 seconds. Later collections had identical content signatures. This reduces requests and fixes membership, but full public API collections still take several seconds.

Testing the web endpoint's `etag` parameter found a much cheaper unchanged response. The initial unconditioned request took 1.21 seconds and returned 88,495 bytes. Three conditional requests took 0.112, 0.110, and 0.188 seconds, each returning 232 bytes. Their JSON contained only `rapidViewId`, `emptyFilterBoard`, and `etagData`, with the same token. This behavior was measured on the connected 8.20.7 server, not inferred from newer Java documentation.

The automatic loop now uses this conditional response as a change hint. It skips public card queries when the token is unchanged, accepts a changed token only after a successful full refresh, and forces full configuration and membership reconciliation every 60 seconds regardless of the token. Unsupported private endpoints fall back to public polling. Unchanged card contents skip cache writes and presentation callbacks. HTTP 429 handling remains shared; failed automatic checks back off up to 60 seconds. Manual refresh always forces a full refresh.

This is polling, not a live subscription. Jira's supported push mechanism requires administrator webhook registration and a reachable HTTP callback. No webhook or callback service was created. [Atlassian webhook documentation](https://developer.atlassian.com/server/jira/platform/webhooks/)
