import CryptoKit
import Darwin
import Foundation

struct RoomError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func validName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0)
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct Stamp: Codable, Equatable {
    let device: Int32
    let inode: UInt64
    let bytes: Int64
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let bornSeconds: Int
    let bornNanos: Int

    init?(_ stat: stat) {
        guard stat.st_mode & S_IFMT == S_IFREG, stat.st_nlink == 1 else { return nil }
        device = stat.st_dev
        inode = stat.st_ino
        bytes = stat.st_size
        modifiedSeconds = stat.st_mtimespec.tv_sec
        modifiedNanos = stat.st_mtimespec.tv_nsec
        bornSeconds = stat.st_birthtimespec.tv_sec
        bornNanos = stat.st_birthtimespec.tv_nsec
    }
}

private final class Directory {
    let fd: Int32
    init(fd: Int32) throws {
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        self.fd = fd
    }

    deinit { close(fd) }

    func child(_ name: String, create: Bool = false) throws -> Directory {
        guard validName(name) else { throw RoomError("Invalid folder name.") }
        if create && mkdirat(fd, name, 0o700) == -1 && errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try Directory(fd: openat(fd, name, O_DIRECTORY | O_NOFOLLOW | O_RDONLY | O_CLOEXEC))
    }

    func absent(_ name: String) -> Bool {
        var attributes = stat()
        return validName(name) && fstatat(fd, name, &attributes, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT
    }

    func exists(_ name: String) -> Bool {
        var attributes = stat()
        return validName(name) && fstatat(fd, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0
    }

    func stamp(_ name: String) -> Stamp? {
        var attributes = stat()
        guard validName(name), fstatat(fd, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return Stamp(attributes)
    }

    func names() throws -> [String] {
        // Open a fresh directory stream so enumerating twice starts from the beginning.
        let cursor = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard cursor >= 0 else { throw RoomError("Couldn’t read this folder.") }
        guard let stream = fdopendir(cursor) else { close(cursor); throw RoomError("Couldn’t open this folder.") }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                break
            }
            let count = Int(entry.pointee.d_namlen)
            if let name = withUnsafeBytes(of: &entry.pointee.d_name, { String(bytes: $0.prefix(count), encoding: .utf8) }),
               validName(name) { result.append(name) }
        }
        return result.sorted()
    }

    func readFile<T>(_ name: String, expected: Stamp, _ body: (FileHandle) throws -> T) -> T? {
        guard validName(name) else { return nil }
        let file = openat(fd, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        var attributes = stat()
        guard fstat(file, &attributes) == 0, Stamp(attributes) == expected,
              let result = try? body(handle), fstat(file, &attributes) == 0,
              Stamp(attributes) == expected, stamp(name) == expected else { return nil }
        return result
    }

    // The data fork's digest cannot account for named resource forks, Finder tags,
    // comments or application-specific metadata. Only incidental download metadata
    // may differ on a disposable copy. Unknown attributes and unreadable lists stay.
    func hasOnlyDownloadMetadata(_ name: String, expected: Stamp) -> Bool {
        let incidental: Set<String> = ["com.apple.quarantine", "com.apple.provenance", "com.apple.macl",
            "com.apple.lastuseddate#PS", "com.apple.metadata:kMDItemWhereFroms", "com.apple.metadata:kMDItemDownloadedDate"]
        return readFile(name, expected: expected) { handle in
            let count = flistxattr(handle.fileDescriptor, nil, 0, 0)
            guard count >= 0, count <= 1024 * 1024 else { return false }
            if count == 0 { return true }
            var buffer = [CChar](repeating: 0, count: count)
            guard flistxattr(handle.fileDescriptor, &buffer, count, 0) == count, buffer.last == 0 else { return false }
            return buffer.split(separator: 0).allSatisfy { bytes in
                guard let attribute = String(bytes: bytes.map { UInt8(bitPattern: $0) }, encoding: .utf8) else { return false }
                return incidental.contains(attribute)
            }
        } == true
    }

    func fileHash(_ name: String, expected: Stamp) -> Data? {
        readFile(name, expected: expected) { handle in
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                hash.update(data: chunk)
            }
            return Data(hash.finalize())
        }
    }

    func move(_ name: String, to destination: Directory, as newName: String) throws {
        guard validName(name), validName(newName) else { throw RoomError("Invalid file name.") }
        guard renameatx_np(fd, name, destination.fd, newName, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private enum Kind: String, Codable {
    case paper, media, archive, cache
    var folder: String {
        switch self {
        case .paper: return "Papers"
        case .media: return "Media"
        case .archive: return "Archives"
        case .cache: return "Staged"
        }
    }
}

private struct Candidate {
    let name: String
    let kind: Kind
    let stamp: Stamp
    let keeper: String?
    var bottleHash: Data? = nil
    var id: String {
        digest(Data("\(name)\u{0}\(stamp.device):\(stamp.inode):\(stamp.bytes):\(stamp.modifiedSeconds):\(stamp.modifiedNanos):\(kind.rawValue):\(bottleHash?.base64EncodedString() ?? "")".utf8))
    }
    var item: [String: Any] { ["id": id, "name": name, "kind": kind.rawValue, "bytes": stamp.bytes] }
}

private struct Move: Codable {
    let name: String
    let destination: String
    let kind: Kind
    let stamp: Stamp
    let keeper: String?
    var bottleHash: Data? = nil
}

final class RoomFolder {
    private let root: Directory
    private let journal: URL
    private let inBottleCache: Bool
    private let folderName: String
    private var history: [[Move]]
    private static let paper = Set("pdf txt md rtf doc docx odt csv xls xlsx ppt pptx pages numbers key".split(separator: " ").map(String.init))
    private static let media = Set("jpg jpeg png heic heif gif webp tiff tif bmp mov mp4 m4v mkv webm aac m4a mp3 wav flac".split(separator: " ").map(String.init))
    private static let archive = Set(["zip", "tar", "tgz", "gz", "bz2", "7z", "rar", "xz"])

    static var homebrewDownloads: URL? {
        #if os(macOS)
        guard let path = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: path)).appendingPathComponent("Library/Caches/Homebrew/downloads")
        #else
        return nil
        #endif
    }

    init(url: URL, journalDirectory: URL, bottleCache: URL? = RoomFolder.homebrewDownloads) throws {
        inBottleCache = bottleCache?.standardizedFileURL.path == url.standardizedFileURL.path
        root = try Directory(fd: open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        var stat = Darwin.stat()
        guard fstat(root.fd, &stat) == 0 else { throw RoomError("Folder unavailable.") }
        folderName = url.lastPathComponent
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let key = digest(Data("\(stat.st_dev):\(stat.st_ino):\(stat.st_birthtimespec.tv_sec):\(stat.st_birthtimespec.tv_nsec)".utf8))
        journal = journalDirectory.appendingPathComponent(key + ".json")
        if FileManager.default.fileExists(atPath: journal.path) {
            history = try JSONDecoder().decode([[Move]].self, from: Data(contentsOf: journal))
        } else {
            history = []
        }
    }

    private func save() throws {
        try JSONEncoder().encode(history).write(to: journal, options: .atomic)
    }

    private func destination(_ kind: Kind, create: Bool = false) throws -> Directory {
        try root.child("Room Reset", create: create).child(kind.folder, create: create)
    }

    private func mongoExport(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".archive") || lower.hasSuffix(".archive.gz") || lower.hasSuffix(".bson") || lower.hasSuffix(".bson.gz")
            || (lower.contains("mongo") && lower.contains("dump") && (lower.hasSuffix(".gz") || lower.hasSuffix(".zip")))
    }

    private func desktopMetadata(_ dir: Directory, name: String, stamp: Stamp) -> Bool {
        guard name == ".DS_Store", dir.hasOnlyDownloadMetadata(name, expected: stamp) else { return false }
        return dir.readFile(name, expected: stamp) { try $0.read(upToCount: 8) == Data([0,0,0,1,66,117,100,49]) } == true
    }

    // Finder and browsers put the copy suffix immediately before the extension.
    private static let copyPattern = try! NSRegularExpression(
        pattern: #"^(.+?)(?: \([0-9]+\)|(?: -)? copy(?: [0-9]+)?)(\.[^.]+(?:\.gz)?)$"#,
        options: [.caseInsensitive])

    private func originalName(for name: String) -> String? {
        let ns = name as NSString
        guard let match = Self.copyPattern.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1)) + ns.substring(with: match.range(at: 2))
    }

    private static let bottlePattern = try! NSRegularExpression(
        pattern: #"^[0-9a-f]{64}--[A-Za-z0-9+@_.-]+[.](?:arm64_|x86_64_)?[a-z][a-z0-9_]*[.]bottle(?:[.][0-9]+)?[.]tar[.]gz$"#)

    private func bottleDigest(original: String, dir: Directory, current: String, stamp: Stamp) -> Data? {
        guard inBottleCache, dir.hasOnlyDownloadMetadata(current, expected: stamp), stamp.modifiedSeconds <= Int(Date().timeIntervalSince1970) - 7 * 86400,
              Self.bottlePattern.firstMatch(in: original, range: NSRange(original.startIndex..., in: original)) != nil,
              dir.readFile(current, expected: stamp, { try $0.read(upToCount: 3) == Data([0x1f, 0x8b, 0x08]) }) == true
        else { return nil }
        return dir.fileHash(current, expected: stamp)
    }

    private func candidates() throws -> [Candidate] {
        var found: [Candidate] = []
        var ordinary: [String: Candidate] = [:]
        var exports: [Int64: [(String, Stamp)]] = [:]
        var protected = Set(history.flatMap { $0 }.compactMap(\.keeper))
        let names = try root.names()
        let markers = Set(["WiredTiger", "WiredTiger.wt", "storage.bson", "mongod.lock", ".git"])
        guard markers.isDisjoint(with: names) else { return [] }
        for name in names {
            guard let stamp = root.stamp(name) else { continue }
            if inBottleCache {
                if let hash = bottleDigest(original: name, dir: root, current: name, stamp: stamp) {
                    found.append(Candidate(name: name, kind: .cache, stamp: stamp, keeper: nil, bottleHash: hash))
                }
                continue
            }
            if name.hasPrefix(".") {
                if desktopMetadata(root, name: name, stamp: stamp) {
                    found.append(Candidate(name: name, kind: .cache, stamp: stamp, keeper: nil))
                }
                continue
            }
            if mongoExport(name) { exports[stamp.bytes, default: []].append((name, stamp)); continue }
            let ext = (name as NSString).pathExtension.lowercased()
            let kind: Kind
            if Self.paper.contains(ext) { kind = .paper }
            else if Self.media.contains(ext) { kind = .media }
            else if Self.archive.contains(ext) { kind = .archive }
            else { continue }
            ordinary[name] = Candidate(name: name, kind: kind, stamp: stamp, keeper: nil)
        }
        var copies: [String: Candidate] = [:]
        var originalHashes: [String: Data] = [:]
        for item in ordinary.values {
            guard let original = originalName(for: item.name), let keeper = ordinary[original],
                  originalName(for: original) == nil, keeper.stamp.bytes == item.stamp.bytes else { continue }
            let keptHash = originalHashes[original] ?? root.fileHash(original, expected: keeper.stamp)
            guard let keptHash, root.hasOnlyDownloadMetadata(item.name, expected: item.stamp),
                  root.fileHash(item.name, expected: item.stamp) == keptHash else { continue }
            originalHashes[original] = keptHash
            protected.insert(original)
            copies[item.name] = Candidate(name: item.name, kind: .cache, stamp: item.stamp, keeper: original)
        }
        for item in ordinary.values where !protected.contains(item.name) {
            found.append(copies[item.name] ?? item)
        }
        for group in exports.values where group.count > 1 {
            var keepers: [Data: String] = [:]
            // Prefer the ordinary name and preserve a keeper referenced by an earlier batch.
            let sorted = group.sorted { lhs, rhs in
                func rank(_ name: String) -> Int {
                    if protected.contains(name) { return 0 }
                    return originalName(for: name) == nil ? 1 : 2
                }
                return (rank(lhs.0), lhs.0) < (rank(rhs.0), rhs.0)
            }
            for (name, stamp) in sorted {
                guard let hash = root.fileHash(name, expected: stamp) else { continue }
                if let keeper = keepers[hash], !protected.contains(name), root.hasOnlyDownloadMetadata(name, expected: stamp) {
                    found.append(Candidate(name: name, kind: .cache, stamp: stamp, keeper: keeper))
                } else if keepers[hash] == nil { keepers[hash] = name }
            }
        }
        return found.sorted { $0.name < $1.name }
    }

    // Reconcile write-ahead records after an interruption. Keep changed or inaccessible
    // destinations on record so overwriting a document never makes it purgeable.
    private func reconcile() throws {
        let previous = history.map(\.count)
        history = history.map { batch in
            batch.filter { move in
                // A completed purge, undo or deliberate removal has no remaining destination.
                // An inaccessible directory or a replacement at the same name stays on record.
                do {
                    let dir = try destination(move.kind)
                    if dir.absent(move.destination) { return false }
                    return root.stamp(move.name) != move.stamp || dir.stamp(move.destination) == move.stamp
                } catch let error as POSIXError where error.code == .ENOENT {
                    return false
                } catch { return true }
            }
        }.filter { !$0.isEmpty }
        if history.map(\.count) != previous { try save() }
    }

    func scan(note: String? = nil) throws -> [String: Any] {
        try reconcile()
        let staged = history.flatMap { $0 }.filter { $0.kind == .cache && ((try? destination(.cache).stamp($0.destination)) == $0.stamp) }
        var result: [String: Any] = ["name": folderName, "items": try candidates().map(\.item),
            "canUndo": !history.isEmpty, "stagedCount": staged.count,
            "stagedBytes": staged.reduce(Int64(0)) { $0 + $1.stamp.bytes }]
        if let note { result["notice"] = note }
        return result
    }

    private func safeDisposable(_ move: Move, at dir: Directory, name: String) -> Bool {
        guard dir.hasOnlyDownloadMetadata(name, expected: move.stamp) else { return false }
        if let previous = move.bottleHash {
            return bottleDigest(original: move.name, dir: dir, current: name, stamp: move.stamp) == previous
        }
        if let keeper = move.keeper {
            let matches = (mongoExport(keeper) && mongoExport(move.name)) || originalName(for: move.name) == keeper
            guard matches, keeper != move.name,
                  let keptStamp = root.stamp(keeper), keptStamp.bytes == move.stamp.bytes,
                  let keptHash = root.fileHash(keeper, expected: keptStamp),
                  let stagedHash = dir.fileHash(name, expected: move.stamp),
                  root.stamp(keeper) == keptStamp else { return false }
            return keptHash == stagedHash && dir.hasOnlyDownloadMetadata(name, expected: move.stamp)
        }
        guard move.name == ".DS_Store" else { return false }
        return dir.readFile(name, expected: move.stamp) { try $0.read(upToCount: 8) == Data([0,0,0,1,66,117,100,49]) } == true
    }

    func tidy(ids: [String]) throws -> [String: Any] {
        let requested = Set(ids)
        let selected = try candidates().filter { requested.contains($0.id) }
        var batch: [Move] = []
        for item in selected {
            let dir = try destination(item.kind, create: true)
            let target: String
            if item.kind == .cache { target = UUID().uuidString }
            else if dir.exists(item.name) {
                let extensionPart = (item.name as NSString).pathExtension
                target = "Sorted-\(UUID().uuidString.prefix(12)).\(extensionPart)"
            } else { target = item.name }
            batch.append(Move(name: item.name, destination: target, kind: item.kind, stamp: item.stamp, keeper: item.keeper, bottleHash: item.bottleHash))
        }
        guard !batch.isEmpty else { return try scan(note: "Files changed. The room has been refreshed.") }
        history.append(batch)
        try save()
        var succeeded: [Move] = []
        for move in batch {
            guard root.stamp(move.name) == move.stamp,
                  move.kind != .cache || safeDisposable(move, at: root, name: move.name),
                  let dir = try? destination(move.kind), (try? root.move(move.name, to: dir, as: move.destination)) != nil else { continue }
            succeeded.append(move)
        }
        history.removeLast()
        if !succeeded.isEmpty { history.append(succeeded) }
        try save()
        return try scan(note: succeeded.count == requested.count ? nil : "Some files changed or could not be moved.")
    }

    func undo() throws -> [String: Any] {
        try reconcile()
        guard let batch = history.popLast() else { return try scan() }
        var pending: [Move] = []
        for move in batch {
            guard let dir = try? destination(move.kind), dir.stamp(move.destination) == move.stamp,
                  (try? dir.move(move.destination, to: root, as: move.name)) != nil else {
                pending.append(move)
                continue
            }
        }
        if !pending.isEmpty { history.append(pending) }
        try save()
        return try scan(note: pending.isEmpty ? nil : "Some files changed or their original names are in use.")
    }

    func purge() throws -> [String: Any] {
        guard let dir = try? destination(.cache) else { return try scan() }
        var kept = false
        history = history.map { batch in
            batch.filter { move in
                guard move.kind == .cache else { return true }
                guard safeDisposable(move, at: dir, name: move.destination),
                      dir.stamp(move.destination) == move.stamp,
                      unlinkat(dir.fd, move.destination, 0) == 0 else { kept = true; return true }
                return false
            }
        }.filter { !$0.isEmpty }
        try save()
        return try scan(note: kept ? "Changed files were kept in Room Reset/Staged." : nil)
    }
}
