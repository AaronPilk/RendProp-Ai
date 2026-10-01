#!/usr/bin/env python3
"""Native AVFoundation execution of the complete production ReflectionVideo.

Only FileStore and the iOS-only MediaImporter module boundary are substituted.
Their probes still read real AVFoundation tracks; no mocked export outcomes.
Synthetic media is generated in a unique private temporary directory.
"""
from pathlib import Path
import hashlib
import array
import math
import json
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[4]
OUT = Path(tempfile.mkdtemp(prefix="rendprop-reflection-video-"))
FFMPEG = shutil.which("ffmpeg")
RECEIPT = {"evidence": str(OUT), "commands": []}


def run(name, cmd):
    result = subprocess.run(cmd, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=240)
    (OUT / (name + ".log")).write_text(result.stdout)
    RECEIPT["commands"].append({"name": name, "command": cmd, "exit": result.returncode})
    (OUT / "receipt.json").write_text(json.dumps(RECEIPT, indent=2) + "\n")
    if result.returncode:
        print(result.stdout[-6000:])
        raise SystemExit(result.returncode)
    return result.stdout


def main():
    print("EVIDENCE", OUT, flush=True)
    assert FFMPEG, "ffmpeg is required"
    fixtures = [("source", "blue", "320x240", 30, 12), ("red", "red", "160x120", 24, 2.4),
                ("green", "green", "320x240", 30, 2.4), ("wrong-shape", "red", "240x240", 30, 2.4),
                ("too-short", "red", "320x240", 30, 1),
                ("portrait-red", "red", "240x320", 30, 2.4),
                ("fractional", "blue", "320x240", "30000/1001", 6),
                ("long", "blue", "32x32", 4, 600.75),
                ("hdr-red", "red", "320x240", 30, 1)]
    for name, color, size, fps, seconds in fixtures:
        cmd = [FFMPEG, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", f"color=c={color}:s={size}:r={fps}"]
        if name == "source": cmd += ["-f", "lavfi", "-i", "aevalsrc=0.25*sin(2*PI*(220*t+40*t*t)):s=48000", "-c:a", "aac"]
        cmd += ["-t", str(seconds), "-c:v", "libx264", "-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-movflags", "+faststart", str(OUT / (name + ".mp4"))]
        run("fixture-" + name, cmd)
    run("fixture-portrait-base", [FFMPEG,"-hide_banner","-loglevel","error","-i",str(OUT/"source.mp4"),
        "-vf","drawbox=x=0:y=0:w=iw/2:h=ih:color=yellow:t=fill","-c:v","libx264","-c:a","copy",str(OUT/"portrait-base.mp4")])
    run("fixture-portrait", [FFMPEG,"-hide_banner","-loglevel","error","-display_rotation","90","-i",str(OUT/"portrait-base.mp4"),
        "-c","copy",str(OUT/"portrait.mp4")])
    run("fixture-hdr", [FFMPEG,"-hide_banner","-loglevel","error","-f","lavfi","-i","smptehdbars=size=320x240:rate=30",
        "-t","3","-c:v","libx265","-x265-params","log-level=error:pools=1:frame-threads=1:colorprim=9:transfer=16:colormatrix=9","-pix_fmt","yuv420p10le",
        "-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc","-tag:v","hvc1",str(OUT/"hdr.mp4")])
    originals = {name: hashlib.sha256((OUT / (name + ".mp4")).read_bytes()).hexdigest() for name, *_ in fixtures}
    for name in ["portrait","hdr"]:
        originals[name]=hashlib.sha256((OUT/(name+".mp4")).read_bytes()).hexdigest()
    source_path = ROOT / "apps/ios/Rendprop/Render/ReflectionVideo.swift"
    production = source_path.read_text()
    RECEIPT["source_sha256"] = hashlib.sha256(production.encode()).hexdigest()
    RECEIPT["test_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    swift = '''
import Foundation
import AVFoundation
struct TimeRange { var startS: Double; var endS: Double }
enum FileStore {
    static func fileSize(_ url: URL) -> Int64 { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 }
}
enum MediaImporter {
    static let maxDurationSeconds: Double = 600
    struct Probe { var hasVideoTrack = false; var isPlayable = false; var duration: Double = 0; var fps: Double = 0; var width = 0; var height = 0 }
    static func probe(url: URL) async -> Probe {
        var p = Probe(); let a = AVURLAsset(url: url)
        p.duration = (try? await a.load(.duration).seconds) ?? 0
        p.isPlayable = (try? await a.load(.isPlayable)) ?? false
        if let t = try? await a.loadTracks(withMediaType: .video).first {
            p.hasVideoTrack = true
            p.fps = Double((try? await t.load(.nominalFrameRate)) ?? 0)
            let size = (try? await t.load(.naturalSize)) ?? .zero
            let tx = (try? await t.load(.preferredTransform)) ?? .identity
            let r = CGRect(origin: .zero, size: size).applying(tx)
            p.width = Int(abs(r.width).rounded()); p.height = Int(abs(r.height).rounded())
        }
        return p
    }
}
''' + production + '''
@main struct Regression {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        func file(_ name: String) -> URL { root.appendingPathComponent(name + ".mp4") }
        var checks = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
        let plan = ReflectionVideo.plan(ranges: [TimeRange(startS: -1, endS: 2), TimeRange(startS: 1, endS: 11),
            TimeRange(startS: 10, endS: 20), TimeRange(startS: .nan, endS: 5), TimeRange(startS: 8, endS: 6)], duration: 12)
        check(plan.count == 3, "Merged 12s produces three clips")
        check(plan.allSatisfy { $0.durationS < 5 && $0.durationS > 0 }, "All strict <5s")
        check(plan.first!.startS == 0 && plan.last!.endS == 12, "No omitted tail")
        check(abs(plan.reduce(0) { $0 + $1.durationS } - 12) < 0.0001, "Full union preserved")
        check(ReflectionVideo.plan(ranges: [], duration: 12).isEmpty, "No invented intervals")
        check(ReflectionVideo.plan(ranges: [TimeRange(startS: 0, endS: 8)], duration: .infinity).isEmpty, "Nonfinite duration blocked")
        let tiny = ReflectionVideo.plan(ranges: [TimeRange(startS: 1, endS: 5.81)], duration: 12)
        check(tiny.count == 2 && tiny.allSatisfy { $0.durationS > 2 }, "Tiny tail divided across clips")
        let first = ReflectionClip(startS: 2, endS: 4.4), second = ReflectionClip(startS: 8, endS: 10.4)
        try await ReflectionVideo.extract(source: file("source"), clip: first, destination: file("extracted"))
        let extracted = await MediaImporter.probe(url: file("extracted"))
        check(extracted.duration < 5 && abs(extracted.duration - 2.4) < 0.035, "Real extract strictly bounded")
        do {
            try await ReflectionVideo.extract(source: file("source"), clip: ReflectionClip(startS: 0, endS: 5), destination: file("invalid"))
            preconditionFailure("5s accepted")
        } catch ReflectionVideo.Failure.invalidRange { checks += 1 }
        try await ReflectionVideo.splice(source: file("source"), replacements: [(first,file("red")),(second,file("green"))], destination: file("spliced"))
        let result = await MediaImporter.probe(url: file("spliced"))
        check(abs(result.duration - 12) < 0.035 && result.width == 320 && result.height == 240, "Complete duration/framing preserved")
        check(try await AVURLAsset(url:file("spliced")).loadTracks(withMediaType:.audio).count == 1, "Original audio retained")
        do {
            try await ReflectionVideo.splice(source: file("source"), replacements: [(first,file("too-short"))], destination: file("short-result"))
            preconditionFailure("short replacement accepted")
        } catch ReflectionVideo.Failure.changedDuration { checks += 1 }
        do {
            try await ReflectionVideo.splice(source: file("source"), replacements: [(first,file("wrong-shape"))], destination: file("shape-result"))
            preconditionFailure("changed aspect accepted")
        } catch ReflectionVideo.Failure.changedFraming { checks += 1 }
        do {
            try await ReflectionVideo.splice(source: file("source"), replacements: [(first,file("red")),(first,file("red"))], destination: file("overlap-result"))
            preconditionFailure("overlap accepted")
        } catch ReflectionVideo.Failure.invalidRange { checks += 1 }
        try await ReflectionVideo.extract(source:file("portrait"),clip:first,destination:file("portrait-extracted"))
        let portraitInput = await MediaImporter.probe(url:file("portrait-extracted"))
        check(portraitInput.width == 240 && portraitInput.height == 320 && abs(portraitInput.duration-2.4)<0.035, "Portrait provider input is correctly oriented")
        try await ReflectionVideo.splice(source:file("portrait"), replacements:[(first,file("portrait-red"))], destination:file("portrait-spliced"))
        let portrait = await MediaImporter.probe(url:file("portrait-spliced"))
        check(portrait.width == 240 && portrait.height == 320 && abs(portrait.duration-12)<0.035, "Portrait transform retained")
        let subframe = ReflectionClip(startS:2.013,endS:4.413)
        try await ReflectionVideo.extract(source:file("fractional"),clip:subframe,destination:file("fractional-extracted"))
        try await ReflectionVideo.splice(source:file("fractional"),replacements:[(subframe,file("red"))],destination:file("fractional-spliced"))
        let fractionalSource = await MediaImporter.probe(url:file("fractional"))
        let fractionalResult = await MediaImporter.probe(url:file("fractional-spliced"))
        check(abs(fractionalSource.duration-fractionalResult.duration)<0.035, "29.97fps non-frame cuts preserve duration")
        do {
            try await ReflectionVideo.extract(source:file("long"),clip:first,destination:file("long-extracted"))
            preconditionFailure("over600 source extracted")
        } catch ReflectionVideo.Failure.invalidRange { checks += 1 }
        do {
            try await ReflectionVideo.splice(source:file("long"),replacements:[(first,file("red"))],destination:file("long-spliced"))
            preconditionFailure("over600 source spliced")
        } catch ReflectionVideo.Failure.noVideo { checks += 1 }
        try await ReflectionVideo.extract(source:file("hdr"),clip:ReflectionClip(startS:0,endS:3),destination:file("hdr-normalized"))
        try await ReflectionVideo.splice(source:file("hdr"),replacements:[(ReflectionClip(startS:1,endS:2),file("hdr-red"))],destination:file("hdr-spliced"))
        let hdr = await MediaImporter.probe(url:file("hdr-spliced"))
        check(hdr.width == 320 && hdr.height == 240 && abs(hdr.duration-3)<0.035,"HDR input produces complete SDR splice")
        let cancelled = Task {
            try await ReflectionVideo.extract(source:file("source"),clip:first,destination:file("cancelled"))
        }
        cancelled.cancel()
        do { try await cancelled.value; preconditionFailure("cancelled extraction completed") }
        catch is CancellationError { checks += 1 }
        let value: [String:Any] = ["checks":checks,"extracted_duration":extracted.duration,"result_duration":result.duration,"width":result.width,"height":result.height]
        print(String(data:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),encoding:.utf8)!)
    }
}
'''
    (OUT / "VideoRegression.swift").write_text(swift)
    run("compile", ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(OUT / "VideoRegression.swift"), "-o", str(OUT / "video-regression")])
    RECEIPT["results"] = json.loads(run("execute", [str(OUT / "video-regression"), str(OUT)]))
    for name, digest in originals.items(): assert hashlib.sha256((OUT / (name + ".mp4")).read_bytes()).hexdigest() == digest
    # Decode real output frames, checking unedited gaps and both replacements.
    frame_results = []
    for seconds, channel in [(1,2),(3,0),(6,2),(9,1),(11,2)]:
        cmd = [FFMPEG,"-hide_banner","-loglevel","error","-ss",str(seconds),"-i",str(OUT/"spliced.mp4"),"-frames:v","1","-vf","scale=1:1","-f","rawvideo","-pix_fmt","rgb24","pipe:1"]
        frame = subprocess.check_output(cmd)
        assert len(frame) == 3 and frame[channel] > 80 and frame[channel] > max(v for i,v in enumerate(frame) if i != channel) + 50, (seconds,list(frame))
        frame_results.append({"at_s":seconds,"rgb":list(frame),"expected_channel":channel})
    def pixels(name, seconds, size="2:2"):
        return subprocess.check_output([FFMPEG,"-hide_banner","-loglevel","error","-ss",str(seconds),"-i",str(OUT/(name+".mp4")),
            "-frames:v","1","-vf","scale="+size+":flags=neighbor","-f","rawvideo","-pix_fmt","rgb24","pipe:1"])
    peer_pixels=[]
    for before,after,seconds in [("portrait","portrait-spliced",1),("portrait","portrait-spliced",6),("portrait","portrait-extracted",1),
                                 ("hdr-normalized","hdr-spliced",0.5),("hdr-normalized","hdr-spliced",2.5)]:
        a,b=pixels(before,seconds),pixels(after,seconds)
        assert len(a)==len(b)==12 and max(abs(x-y) for x,y in zip(a,b))<=12,(before,after,seconds,list(a),list(b))
        peer_pixels.append({"reference":before,"output":after,"at_s":seconds,"max_rgb_delta":max(abs(x-y) for x,y in zip(a,b))})
    for seconds,channel in [(1.9,2),(2.1,0),(4.5,2)]:
        rgb=pixels("fractional-spliced",seconds,"1:1")
        assert rgb[channel]>max(v for i,v in enumerate(rgb) if i!=channel)+50,(seconds,list(rgb))
        peer_pixels.append({"output":"fractional-spliced","at_s":seconds,"rgb":list(rgb)})
    ffprobe=shutil.which("ffprobe")
    color_results={}
    for name in ["hdr","hdr-normalized","hdr-spliced"]:
        probe=json.loads(subprocess.check_output([ffprobe,"-v","error","-select_streams","v:0","-show_entries",
            "stream=color_primaries,color_transfer,color_space","-of","json",str(OUT/(name+".mp4"))]))["streams"][0]
        color_results[name]=probe
    assert color_results["hdr"]["color_transfer"]=="smpte2084"
    for name in ["hdr-normalized","hdr-spliced"]:
        assert color_results[name]=={"color_space":"bt709","color_transfer":"bt709","color_primaries":"bt709"},color_results
    def pcm(name):
        values=array.array("f")
        values.frombytes(subprocess.check_output([FFMPEG,"-hide_banner","-loglevel","error","-i",str(OUT/(name+".mp4")),
            "-vn","-ac","1","-ar","48000","-f","f32le","pipe:1"]))
        return values
    original_audio,result_audio=pcm("source"),pcm("spliced")
    assert original_audio.tobytes()==result_audio.tobytes(), "Complete decoded original audio changed"
    RECEIPT["complete_audio"]={"samples":len(original_audio),"sample_rate":48000,"exact_pcm_match":True,
        "sha256":hashlib.sha256(original_audio.tobytes()).hexdigest()}
    audio_checks=[]
    for start,end in [(0.1,1.9),(2.1,4.2),(4.5,7.9),(8.1,10.2),(10.5,11.9)]:
        a=original_audio[int(start*48000):int(end*48000):8]; b=result_audio[int(start*48000):int(end*48000):8]
        assert len(a)==len(b)>0
        correlation=sum(x*y for x,y in zip(a,b))/math.sqrt(sum(x*x for x in a)*sum(y*y for y in b))
        assert correlation>0.985,(start,end,correlation)
        audio_checks.append({"start_s":start,"end_s":end,"zero_lag_waveform_correlation":correlation})
    RECEIPT["peer_pixel_checks"]=peer_pixels
    RECEIPT["color_profiles"]=color_results
    RECEIPT["original_audio_checks"]=audio_checks
    RECEIPT["pixel_checks"] = frame_results
    RECEIPT["original_hashes_unchanged"] = originals
    assert source_path.read_text() == production, "Production source changed during verification"
    assert hashlib.sha256(Path(__file__).read_bytes()).hexdigest() == RECEIPT["test_sha256"], "Test changed during verification"
    RECEIPT["completed"] = True
    (OUT / "receipt.json").write_text(json.dumps(RECEIPT, indent=2) + "\n")
    print(json.dumps(RECEIPT["results"]), "and 13 decoded-frame checks, 5 audio waveform checks, 3 color profiles; all source hashes unchanged", flush=True)


if __name__ == "__main__": main()
