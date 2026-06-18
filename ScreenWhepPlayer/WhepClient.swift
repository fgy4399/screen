import Foundation

struct WhepEndpoint {
    let url: URL
    let bearerToken: String?
}

struct WhepSession {
    let answerSDP: String
    let resourceURL: URL?
}

enum WhepClientError: LocalizedError {
    case invalidResponse
    case httpStatus(Int, String)
    case emptyAnswer

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "WHEP server returned a non-HTTP response."
        case let .httpStatus(code, body):
            return "WHEP server returned HTTP \(code): \(body)"
        case .emptyAnswer:
            return "WHEP server returned an empty SDP answer."
        }
    }
}

final class WhepClient {
    private let endpoint: WhepEndpoint
    private let session: URLSession

    init(endpoint: WhepEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func createSession(offerSDP: String, completion: @escaping (Result<WhepSession, Error>) -> Void) {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.setValue("application/sdp", forHTTPHeaderField: "Accept")
        request.httpBody = Data(offerSDP.utf8)

        if let bearerToken = endpoint.bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(WhepClientError.invalidResponse))
                return
            }

            let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
            guard (200...299).contains(httpResponse.statusCode) else {
                completion(.failure(WhepClientError.httpStatus(httpResponse.statusCode, body)))
                return
            }

            let answer = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else {
                completion(.failure(WhepClientError.emptyAnswer))
                return
            }

            let resourceURL = self.resolveResourceURL(from: httpResponse)
            completion(.success(WhepSession(answerSDP: answer, resourceURL: resourceURL)))
        }.resume()
    }

    func deleteSession(resourceURL: URL, completion: ((Error?) -> Void)? = nil) {
        var request = URLRequest(url: resourceURL)
        request.httpMethod = "DELETE"

        if let bearerToken = endpoint.bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        session.dataTask(with: request) { _, _, error in
            completion?(error)
        }.resume()
    }

    private func resolveResourceURL(from response: HTTPURLResponse) -> URL? {
        guard let location = response.value(forHTTPHeaderField: "Location"), !location.isEmpty else {
            return nil
        }

        return URL(string: location, relativeTo: endpoint.url)?.absoluteURL
    }
}
