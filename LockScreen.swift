import AppKit
import AVFoundation

// The lock screen shows the system wallpaper, and macOS offers no API to set a custom video as one.
// So (like Wallper) we register the video as a custom "aerial" in the user's wallpaper manifest and
// point the system wallpaper at it. Files touched: aerials/manifest/entries.json and Store/Index.plist.
// shortcut: undocumented macOS internals, a system update can change them; re-applied on launch if the entry vanishes.
enum LockScreen {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper")
    static let aerials = base.appendingPathComponent("aerials")
    static let manifest = aerials.appendingPathComponent("manifest/entries.json")
    static let index = base.appendingPathComponent("Store/Index.plist")
    static let prefix = "11FE0A11-0000-4000-8000-"          // every id we create starts with this
    static let category = prefix + "0000000000C1", subcategory = prefix + "0000000000C2"

    static func isInstalled(_ id: String) -> Bool {
        ((try? String(contentsOf: manifest, encoding: .utf8)) ?? "").contains(id)
    }

    // The lock screen player hitches at the loop point of very short clips (a 0.6s one froze), so clips
    // under 30s are repeated into one longer file, losslessly. Longer ones are just copied.
    static func stage(_ video: URL, to dst: URL) throws {
        let asset = AVURLAsset(url: video)
        let dur = asset.duration
        guard dur.seconds > 0, dur.seconds < 30 else { try FileManager.default.copyItem(at: video, to: dst); return }
        let comp = AVMutableComposition()
        for type in [AVMediaType.video, .audio] {
            guard let src = asset.tracks(withMediaType: type).first,
                  let track = comp.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            track.preferredTransform = src.preferredTransform
            var at = CMTime.zero
            while at.seconds < 30 {
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: src, at: at)
                at = CMTimeAdd(at, dur)
            }
        }
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { throw Failure(description: "can't export \(video.lastPathComponent)") }
        ex.outputURL = dst; ex.outputFileType = .mov
        let done = DispatchSemaphore(value: 0)
        ex.exportAsynchronously { done.signal() }
        done.wait()
        if ex.status != .completed { throw Failure(description: "looping failed: \(ex.error?.localizedDescription ?? "unknown")") }
    }

    // Returns the new asset id. A new id per change, so the system never serves a cached older video.
    static func apply(_ video: URL, title: String) throws -> String {
        let fm = FileManager.default
        let id = prefix + String(UUID().uuidString.suffix(12))
        let videoDst = aerials.appendingPathComponent("videos/\(id).mov")
        let thumbDst = aerials.appendingPathComponent("thumbnails/\(id).png")

        // 0. read and validate everything first, so an unsupported layout fails before any file is touched
        guard let data = try? Data(contentsOf: manifest),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var assets = root["assets"] as? [[String: Any]],
              var cats = root["categories"] as? [[String: Any]] else { throw Failure(description: "can't read \(manifest.path)") }
        var fmt = PropertyListSerialization.PropertyListFormat.binary
        guard var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: index), options: [], format: &fmt) as? [String: Any]
        else { throw Failure(description: "can't read \(index.path)") }
        let config = try PropertyListSerialization.data(fromPropertyList: ["assetID": id], format: .binary, options: 0)
        var changed = 0
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            guard var scope = plist[key] as? [String: Any] else { continue }
            // "Linked": one config for desktop and lock screen. Otherwise macOS keeps a "Desktop" and an "Idle"
            // (lock screen / screen saver) config; we set all that exist, since the desktop is covered by LiveWall anyway.
            // shortcut: the Desktop/Idle layout is untested on real hardware, confirm on a Mac that has it.
            var touched = false
            for slot in ["Linked", "Desktop", "Idle"] {
                guard var s = scope[slot] as? [String: Any], var content = s["Content"] as? [String: Any] else { continue }
                content["Choices"] = [["Configuration": config, "Files": [Any](), "Provider": "com.apple.wallpaper.choice.aerials"]]
                s["Content"] = content; s["LastSet"] = Date(); s["LastUse"] = Date()
                scope[slot] = s; touched = true
            }
            if touched { plist[key] = scope; changed += 1 }
        }
        guard changed > 0 else {
            let keys = (plist["AllSpacesAndDisplays"] as? [String: Any])?.keys.sorted() ?? []
            throw Failure(description: "unsupported wallpaper layout (AllSpacesAndDisplays keys: \(keys)). Please report this on GitHub.")
        }

        // 1. files
        try fm.createDirectory(at: videoDst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: thumbDst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try stage(video, to: videoDst)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1280, height: 720)
        let png = NSBitmapImageRep(cgImage: try gen.copyCGImage(at: .zero, actualTime: nil)).representation(using: .png, properties: [:])
        try png?.write(to: thumbDst)

        // 2. manifest: drop our old entries (and their files), add the new one
        for old in assets.compactMap({ $0["id"] as? String }) where old.hasPrefix(prefix) {
            try? fm.removeItem(at: aerials.appendingPathComponent("videos/\(old).mov"))
            try? fm.removeItem(at: aerials.appendingPathComponent("thumbnails/\(old).png"))
        }
        assets.removeAll { ($0["id"] as? String)?.hasPrefix(prefix) == true }
        assets.append([
            "accessibilityLabel": title, "localizedNameKey": title, "id": id,
            "categories": [category], "subcategories": [subcategory],
            "includeInShuffle": false, "pointsOfInterest": [String: String](), "preferredOrder": 0,
            "previewImage": thumbDst.absoluteString, "shotID": "LIVEWALL_" + id.suffix(12),
            "showInTopLevel": true, "url-4K-SDR-240FPS": videoDst.absoluteString,
        ])
        func entry(_ catID: String, subs: [[String: Any]]? = nil) -> [String: Any] {
            var e: [String: Any] = ["id": catID, "localizedDescriptionKey": "LiveWall", "localizedNameKey": "LiveWall",
                                    "preferredOrder": 0, "previewImage": thumbDst.absoluteString, "representativeAssetID": id]
            if let subs { e["subcategories"] = subs }
            return e
        }
        cats.removeAll { ($0["id"] as? String) == category }
        cats.append(entry(category, subs: [entry(subcategory)]))
        root["assets"] = assets; root["categories"] = cats; root["initialAssetCount"] = assets.count
        try JSONSerialization.data(withJSONObject: root).write(to: manifest, options: .atomic)

        // 3. point the system wallpaper at it
        try PropertyListSerialization.data(fromPropertyList: plist, format: fmt, options: 0).write(to: index, options: .atomic)

        // 4. the agent re-reads its config on restart; launchd brings it back by itself
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/killall"); p.arguments = ["WallpaperAgent"]
        try p.run(); p.waitUntilExit()
        return id
    }
}
