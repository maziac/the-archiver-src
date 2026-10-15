// Minimaler Client für die App Store Connect API (JWT ES256 mit CryptoKit, keine Abhängigkeiten).
//
//   ASC_KEY_ID=… ASC_ISSUER_ID=… swift scripts/asc.swift GET  '/v1/bundleIds?filter[identifier]=com.tb.archiver'
//   ASC_KEY_ID=… ASC_ISSUER_ID=… swift scripts/asc.swift POST /v1/bundleIds body.json
//
// Schlüssel: ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8 (oder ASC_KEY_PATH).
// Gibt die JSON-Antwort auf stdout aus; Exit-Code 1 bei HTTP-Fehler.
import CryptoKit
import Foundation

let env = ProcessInfo.processInfo.environment
guard let keyID = env["ASC_KEY_ID"], let issuer = env["ASC_ISSUER_ID"] else {
    FileHandle.standardError.write("ASC_KEY_ID und ASC_ISSUER_ID setzen\n".data(using: .utf8)!)
    exit(2)
}
let args = CommandLine.arguments.dropFirst()
guard args.count >= 2 else {
    FileHandle.standardError.write("Aufruf: asc.swift GET|POST|PATCH|DELETE <pfad> [body.json]\n".data(using: .utf8)!)
    exit(2)
}
let method = args[args.startIndex], path = args[args.startIndex + 1]
let body = args.count > 2 ? try Data(contentsOf: URL(fileURLWithPath: args[args.startIndex + 2])) : nil

let keyPath = env["ASC_KEY_PATH"] ?? NSString(string: "~/.appstoreconnect/private_keys/AuthKey_\(keyID).p8").expandingTildeInPath
let key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: keyPath, encoding: .utf8))

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

let now = Int(Date().timeIntervalSince1970)
let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"])
let claims = try JSONSerialization.data(withJSONObject: ["iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"])
let unsigned = base64URL(header) + "." + base64URL(claims)
let signature = try key.signature(for: Data(unsigned.utf8)).rawRepresentation
let token = unsigned + "." + base64URL(signature)

var request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com" + path)!)
request.httpMethod = method
request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
if let body {
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
}

let (data, response) = try await URLSession.shared.data(for: request)
FileHandle.standardOutput.write(data)
let status = (response as? HTTPURLResponse)?.statusCode ?? 0
if !(200..<300).contains(status) {
    FileHandle.standardError.write("HTTP \(status)\n".data(using: .utf8)!)
    exit(1)
}
