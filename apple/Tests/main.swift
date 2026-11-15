import Darwin
import Foundation

struct Failure: Error, CustomStringConvertible { let description: String }
func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(description: message) }
}
func items(_ scan: [String: Any]) -> [[String: Any]] { scan["items"] as! [[String: Any]] }
func ids(_ scan: [String: Any]) -> [String] { items(scan).map { $0["id"] as! String } }
func names(_ scan: [String: Any]) -> Set<String> { Set(items(scan).map { $0["name"] as! String }) }
func put(_ data: Data, _ name: String, in folder: URL) throws {
    try data.write(to: folder.appendingPathComponent(name))
}
func exists(_ name: String, in dir: URL) -> Bool {
    FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
}
func fixture(_ test: (URL, URL, RoomFolder) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("RoomResetTests-" + UUID().uuidString)
    let folder = base.appendingPathComponent("Inbox")
    let ledger = base.appendingPathComponent("History")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try test(folder, ledger, RoomFolder(url: folder, journalDirectory: ledger))
}

let one = Data("one".utf8)
let two = Data("two".utf8)
let meta = Data([0,0,0,1,66,117,100,49,1,2,3])
let tests: [(String, (URL, URL, RoomFolder) throws -> Void)] = [
    ("Organize all categories, preserve collisions, reopen and undo", { dir, ledger, room in
        for name in ["bill.pdf", "pup.png", "album.zip", "source.swift"] { try put(one, name, in: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Room Reset/Papers"), withIntermediateDirectories: true)
        try put(two, "Room Reset/Papers/bill.pdf", in: dir)
        let before = try room.scan()
        try check(names(before) == ["bill.pdf", "pup.png", "album.zip"], "wrong classifications")
        let sorted = try room.tidy(ids: ids(before))
        try check(names(sorted).isEmpty && sorted["canUndo"] as? Bool == true, "items not moved")
        try check(try Data(contentsOf: dir.appendingPathComponent("Room Reset/Papers/bill.pdf")) == two, "collision overwritten")
        try check(exists("Room Reset/Media/pup.png", in: dir) && exists("Room Reset/Archives/album.zip", in: dir), "missing destination")
        let fresh = try RoomFolder(url: dir, journalDirectory: ledger)
        let undone = try fresh.undo()
        try check(names(undone) == names(before) && undone["canUndo"] as? Bool == false, "restart undo")
        try check(try Data(contentsOf: dir.appendingPathComponent("bill.pdf")) == one, "wrong restored content")
    }),
    ("Stage and purge exact copies and recognized Finder metadata", { dir, _, room in
        for name in ["dump.archive.gz","dump (1).archive.gz","unique.archive","report.pdf","report (1).pdf","pic.png","pic copy.png"] {
            try put(one, name, in: dir)
        }
        try put(two, "unique.archive", in: dir)
        try put(two, "report (2).pdf", in: dir)
        try put(meta, ".DS_Store", in: dir)
        let before = try room.scan()
        let disposables = items(before).filter { $0["kind"] as? String == "cache" }
        let expected = Set(["dump (1).archive.gz","report (1).pdf","pic copy.png",".DS_Store"])
        try check(Set(disposables.map { $0["name"] as! String }) == expected, "unsafe duplicate selection")
        let stage = try room.tidy(ids: disposables.map { $0["id"] as! String })
        try check(stage["stagedCount"] as? Int == 4 && Set(["dump.archive.gz","report.pdf","pic.png"]).isDisjoint(with: names(stage)), "keepers became tidy candidates")
        let end = try room.purge()
        try check(end["stagedCount"] as? Int == 0 && end["canUndo"] as? Bool == false, "purge failed")
        for kept in ["dump.archive.gz","report.pdf","pic.png","unique.archive","report (2).pdf"] { try check(exists(kept, in: dir), "keeper missing") }
    }),
    ("Recheck keeper at purge and safely retry undo after a name conflict", { dir, _, room in
        try put(one, "lake.png", in: dir); try put(one, "lake copy.png", in: dir)
        _ = try room.tidy(ids: ids(room.scan()))
        try put(two, "lake.png", in: dir)
        let kept = try room.purge()
        try check(kept["stagedCount"] as? Int == 1, "changed keeper allowed purge")
        try put(two, "lake copy.png", in: dir)
        let conflict = try room.undo()
        try check(conflict["canUndo"] as? Bool == true && (try? Data(contentsOf: dir.appendingPathComponent("lake copy.png"))) == two, "conflict overwritten")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("lake copy.png"))
        let restored = try room.undo()
        try check(restored["canUndo"] as? Bool == false && (try? Data(contentsOf: dir.appendingPathComponent("lake copy.png"))) == one, "retry failed")
    }),
    ("Ignore links, spoofed metadata, active datastore and source roots", { dir, ledger, room in
        try put(one, "one.pdf", in: dir)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link.pdf"), withDestinationURL: dir.appendingPathComponent("one.pdf"))
        try FileManager.default.linkItem(at: dir.appendingPathComponent("one.pdf"), to: dir.appendingPathComponent("hard.pdf"))
        try put(one, ".DS_Store", in: dir)
        try check(names(room.scan()).isEmpty, "linked or spoofed file offered")
        try put(one, "a.pdf", in: dir)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("Room Reset"), withDestinationURL: ledger)
        do {
            _ = try room.tidy(ids: ids(room.scan()))
            throw Failure(description: "followed destination symlink")
        } catch is POSIXError {}
        try check(exists("a.pdf", in: dir) && !exists("Papers", in: ledger), "symlink escape")
        try put(one, "storage.bson", in: dir)
        try check(names(room.scan()).isEmpty, "database directory exposed")
    }),
    ("Resource forks and Finder tags survive duplicate scans and purge", { dir, _, room in
        func attribute(_ key: String, at url: URL) throws {
            let bytes = Array("unique metadata".utf8)
            guard setxattr(url.path, key, bytes, bytes.count, 0, 0) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        for name in ["photo.png", "photo copy.png", "photo (1).png", "photo (2).png", "photo (3).png"] {
            try put(one, name, in: dir)
        }
        try attribute("com.apple.ResourceFork", at: dir.appendingPathComponent("photo copy.png"))
        try attribute("com.apple.metadata:_kMDItemUserTags", at: dir.appendingPathComponent("photo (1).png"))
        try attribute("org.roomreset.test-user-annotation", at: dir.appendingPathComponent("photo (2).png"))
        let disposable = items(try room.scan()).filter { $0["kind"] as? String == "cache" }
        try check(disposable.count == 1 && disposable[0]["name"] as? String == "photo (3).png", "unique metadata exposed for disposal")
        _ = try room.tidy(ids: disposable.map { $0["id"] as! String })
        let staging = dir.appendingPathComponent("Room Reset/Staged")
        let staged = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)[0]
        try attribute("com.apple.ResourceFork", at: staged)
        _ = try room.purge()
        try check(FileManager.default.fileExists(atPath: staged.path), "purge destroyed newly attached resource fork")
        try check(getxattr(staged.path, "com.apple.ResourceFork", nil, 0, 0, 0) > 0, "resource fork was lost")
    }),
    ("Only aged, recognizable Homebrew bottles in the selected cache can be purged", { dir, ledger, _ in
        let downloads = dir.appendingPathComponent("Library/Caches/Homebrew/downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let key = String(repeating: "a", count: 64)
        let old = key + "--test-1.0.arm64_tahoe.bottle.tar.gz"
        let recent = key + "--new-2.0.sonoma.bottle.tar.gz"
        let fake = key + "--fake-1.0.arm64_tahoe.bottle.tar.gz"
        let gzip = Data([31,139,8,0,0,0,0,0,0,0])
        for name in [old, recent, fake, "private.tar.gz"] {
            try put(name == fake ? one : gzip, name, in: downloads)
            if name != recent {
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -9 * 86400)],
                                                      ofItemAtPath: downloads.appendingPathComponent(name).path)
            }
        }
        let room = try RoomFolder(url: downloads, journalDirectory: ledger, bottleCache: downloads)
        try check(names(room.scan()) == [old], "offered recent/unrecognized cache files")
        let stage = try room.tidy(ids: ids(room.scan()))
        try check(stage["stagedCount"] as? Int == 1 && names(stage).isEmpty, "bottle was not staged")
        try check(try room.purge()["stagedCount"] as? Int == 0, "bottle failed purge")
        for name in [recent, fake, "private.tar.gz"] { try check(exists(name, in: downloads), "unrelated cache file removed") }
    }),
    ("Stale scan cannot move a replacement, only last batch is undone", { dir, _, room in
        try put(one, "a.txt", in: dir)
        let old = try room.scan()
        try FileManager.default.removeItem(at: dir.appendingPathComponent("a.txt"))
        try put(two, "a.txt", in: dir)
        try check(names(room.tidy(ids: ids(old))) == ["a.txt"], "stale file moved")
        _ = try room.tidy(ids: ids(room.scan()))
        try put(one, "b.pdf", in: dir)
        _ = try room.tidy(ids: ids(room.scan()))
        let once = try room.undo()
        try check(names(once) == ["b.pdf"] && once["canUndo"] as? Bool == true, "undo ignored batch boundaries")
        try check(names(room.undo()) == ["a.txt", "b.pdf"], "second undo failed")
    })
]
do {
    for (title, test) in tests { try fixture(test); print("PASS  " + title) }
} catch {
    FileHandle.standardError.write(Data("FAIL  \(error)\n".utf8))
    exit(1)
}
