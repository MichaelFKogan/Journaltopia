import Foundation
import Supabase

enum SupabaseConfigurationError: LocalizedError {
    case missingValue(String)
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let key):
            return "Missing \(key). Add it to your local Supabase xcconfig."
        case .invalidURL(let key):
            return "\(key) must be a valid URL."
        }
    }
}

enum JournaltopiaSupabaseConfig {
    static let redirectHost = "auth-callback"

    static var projectURL: URL {
        get throws {
            let rawValue = try infoValue(for: "SUPABASE_URL")
            guard let url = URL(string: rawValue) else {
                throw SupabaseConfigurationError.invalidURL("SUPABASE_URL")
            }
            return url
        }
    }

    static var anonKey: String {
        get throws {
            try infoValue(for: "SUPABASE_ANON_KEY")
        }
    }

    static var redirectScheme: String {
        (try? infoValue(for: "JOURNALTOPIA_AUTH_REDIRECT_SCHEME")) ?? "journaltopia"
    }

    static var redirectURL: URL {
        URL(string: "\(redirectScheme)://\(redirectHost)")!
    }

    private static func infoValue(for key: String) throws -> String {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
            !value.isEmpty,
            !value.hasPrefix("$(")
        else {
            throw SupabaseConfigurationError.missingValue(key)
        }

        return value
    }
}

enum SupabaseService {
    static let shared: SupabaseClient = {
        do {
            return SupabaseClient(
                supabaseURL: try JournaltopiaSupabaseConfig.projectURL,
                supabaseKey: try JournaltopiaSupabaseConfig.anonKey
            )
        } catch {
            return SupabaseClient(
                supabaseURL: URL(string: "https://example.supabase.co")!,
                supabaseKey: "missing-supabase-anon-key"
            )
        }
    }()
}
