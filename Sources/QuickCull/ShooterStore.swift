import Foundation
import ImageIO

/// The little JSON brain behind ingest: which camera bodies belong to which
/// shooter, and which memory cards we've seen before. Deliberately NOT a
/// catalog - it records what the user TAUGHT the app (one "whose camera?"
/// answer per body, ever), so it's user data: it lives beside ratings.json
/// in Application Support and survives cache clears.
final class ShooterStore {

    static let shared = ShooterStore()

    struct Shooter: Codable, Equatable {
        var name: String     // "Ansel Adams"
        var prefix: String   // "ansel" - card folders become ansel-01, ansel-02…
    }

    struct CardMemory: Codable {
        var lastJob: String
        var lastFolder: String   // where this card's photos landed
        var lastDate: Date
    }

    private struct State: Codable {
        var shooters: [Shooter] = []
        var serials: [String: String] = [:]   // camera body serial → shooter prefix
        var cards: [String: CardMemory] = [:] // card volume UUID → last visit
        // serial → model name ("Canon EOS R6"). DECORATION ONLY - identity
        // is always the serial; two R6 bodies never merge. Optional so
        // pre-model shooters.json files still decode.
        var models: [String: String]? = nil
    }

    private var state = State()

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("QuickCull", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("shooters.json")
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(State.self, from: data) {
            state = loaded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Shooters

    var shooters: [Shooter] { state.shooters }

    func updateShooter(prefix: String, newName: String, newPrefix: String) {
        guard let index = state.shooters.firstIndex(where: { $0.prefix == prefix }) else { return }
        state.shooters[index].name = newName
        state.shooters[index].prefix = newPrefix
        if newPrefix != prefix {
            // Camera assignments follow the shooter through the rename.
            for (serial, p) in state.serials where p == prefix {
                state.serials[serial] = newPrefix
            }
        }
        save()
    }

    func removeShooter(prefix: String) {
        state.shooters.removeAll { $0.prefix == prefix }
        state.serials = state.serials.filter { $0.value != prefix }
        save()
    }

    @discardableResult
    func addShooter(name: String, prefix: String) -> Shooter {
        let cleaned = Shooter(name: name.trimmingCharacters(in: .whitespaces),
                              prefix: prefix.lowercased().trimmingCharacters(in: .whitespaces))
        if let existing = state.shooters.first(where: { $0.prefix == cleaned.prefix }) { return existing }
        state.shooters.append(cleaned)
        save()
        return cleaned
    }

    func shooter(forSerial serial: String) -> Shooter? {
        guard let prefix = state.serials[serial] else { return nil }
        return state.shooters.first { $0.prefix == prefix }
    }

    /// The one-time teaching moment: this body belongs to this shooter, forever.
    func assign(serial: String, to prefix: String, model: String? = nil) {
        state.serials[serial] = prefix
        if let model { noteModelNoSave(model, forSerial: serial) }
        save()
    }

    func noteModel(_ model: String, forSerial serial: String) {
        noteModelNoSave(model, forSerial: serial)
        save()
    }

    private func noteModelNoSave(_ model: String, forSerial serial: String) {
        var models = state.models ?? [:]
        models[serial] = model
        state.models = models
    }

    func cameraModel(forSerial serial: String) -> String? {
        state.models?[serial]
    }

    /// "Canon EOS R6" → "R6": strip the maker throat-clearing for UI use.
    /// "Canon EOS R6" → "Canon R6": the BRAND stays (it's how shooters
    /// talk about bodies), only the series noise goes.
    static func shortModel(_ model: String) -> String {
        var m = model
        for (noise, brand) in [("Canon EOS ", "Canon "), ("NIKON ", "Nikon "),
                               ("SONY ", "Sony "), ("FUJIFILM ", "Fujifilm ")] {
            if m.hasPrefix(noise) { m = brand + String(m.dropFirst(noise.count)); break }
        }
        return m
    }

    // MARK: - Cards

    func cardMemory(volumeUUID: String) -> CardMemory? { state.cards[volumeUUID] }

    func rememberCard(volumeUUID: String, job: String, folder: String) {
        state.cards[volumeUUID] = CardMemory(lastJob: job, lastFolder: folder, lastDate: Date())
        save()
    }

    // MARK: - Folder-native card counter

    /// Next "<prefix>-NN" in `dir` - no stored counter, the FILESYSTEM is the
    /// counter: scan existing folders, take max + 1. Folder-native to the end.
    static func nextCardFolderName(prefix: String, in dir: URL) -> String {
        let fm = FileManager.default
        let existing = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var highest = 0
        for name in existing where name.hasPrefix(prefix + "-") {
            if let n = Int(name.dropFirst(prefix.count + 1)) { highest = max(highest, n) }
        }
        return String(format: "%@-%02d", prefix, highest + 1)
    }

    // MARK: - Reading the card

    /// Camera body serial + model from a photo's header (cheap: metadata
    /// only - the model rides in the same read, zero extra I/O).
    static func cameraInfo(of url: URL) -> (serial: String, model: String?)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let serial = exif?[kCGImagePropertyExifBodySerialNumber] as? String, !serial.isEmpty else { return nil }
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        return (serial, model?.isEmpty == false ? model : nil)
    }

    /// The card's volume UUID - how a re-inserted card recognizes itself.
    static func volumeUUID(of url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }
}
