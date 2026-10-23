import Foundation

struct BoardChangeToken: Sendable {
    let value: String
    let unchanged: Bool
}

extension JiraClient {
    /// Jira's web client uses this conditional response to avoid rebuilding unchanged boards.
    /// Use it only as a hint between full public-API reconciliations, not as a source of card fields.
    func boardChangeToken(site: JiraSite, token: String, boardID: Int, previous: String?) async throws -> BoardChangeToken {
        var query = [URLQueryItem(name: "rapidViewId", value: String(boardID))]
        if let previous { query.append(URLQueryItem(name: "etag", value: previous)) }
        let data = try await fetch("xboard/work/allData.json", site: site, token: token, queryItems: query, greenhopper: true)
        struct Response: Decodable {
            let rapidViewId: Int
            let etagData: ETag
            struct ETag: Decodable { let rapidViewId: Int; let etag: String }
        }
        let response: Response = try decode(data)
        guard response.rapidViewId == boardID, response.etagData.rapidViewId == boardID,
              !response.etagData.etag.isEmpty else { throw JiraError.invalidResponse }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return BoardChangeToken(value: response.etagData.etag,
            unchanged: previous == response.etagData.etag && object?["issuesData"] == nil)
    }
}
