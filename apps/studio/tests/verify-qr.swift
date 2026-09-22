// Optional macOS independent decoder for the browser's exported QR artifact.
import Foundation
import Vision
let request = VNDetectBarcodesRequest()
request.symbologies = [.qr]
try VNImageRequestHandler(url: URL(fileURLWithPath: CommandLine.arguments[1]), options: [:]).perform([request])
let payloads = (request.results ?? []).compactMap(\.payloadStringValue)
guard payloads == [CommandLine.arguments[2]] else {
    fputs("QR payload did not match the expected tour URL\n", stderr)
    exit(1)
}
print("QR independently decoded to the expected tour URL")
