import Foundation

// A real Foundation URLSession request checks the platform networking path,
// without claiming a simulator camera test or an iPhone background handover.
// Use only the already-completed synthetic fixture. No fresh ticket or R2 write
// is authorized by this test: the gateway must return its durable stored ETag.
@main struct NativeGatewayProof {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw Failure.invalid }
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let state = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("private-state.json"))) as? [String: Any]
            guard let assets = state?["assets"] as? [String: Any],
                  let asset = assets["single.mp4"] as? [String: Any],
                  let completed = asset["completed"] as? [String: Any], completed["uploaded"] as? Bool == true,
                  let ticket = asset["ticket"] as? [String: Any],
                  let rawURL = ticket["put_url"] as? String,
                  let url = URL(string: rawURL), url.scheme == "https", url.host == "uploads.rendprop.com"
            else { throw Failure.invalid }
            let payload = try Data(contentsOf: directory.appendingPathComponent("synthetic.mp4"))
            guard payload.count == 1855 else { throw Failure.invalid }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.timeoutInterval = 25
            request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
            // Do not override User-Agent: exercise Foundation's actual default.
            let (_, response) = try await URLSession.shared.upload(for: request, from: payload)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let etag = http.value(forHTTPHeaderField: "ETag"), !etag.isEmpty
            else { throw Failure.invalid }
            print("PASS: native URLSession default client receives HTTP200 with stored ETag")
        } catch {
            // URLSession errors can contain capability URLs. Never print them.
            fputs("FAIL: native gateway fixture assertion\n", stderr)
            exit(1)
        }
    }
    enum Failure: Error { case invalid }
}
