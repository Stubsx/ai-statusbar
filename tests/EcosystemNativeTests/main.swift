import Cocoa
import SwiftUI

enum PetMood: Equatable { case loading, working(taskCount: Int), idle, sleeping, celebrating, error }
enum PetImageCache { static func remove(at url: URL) {} }
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    checks += 1
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let fm = FileManager.default
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let template = root.appendingPathComponent("template")
try PetSharing.makeTemplate(at: template)
var metadata = PetSharing.manifest(at: template)
metadata["nsfw"] = true
metadata["author"] = "测试创作者"
try JSONSerialization.data(withJSONObject: metadata).write(to: template.appendingPathComponent("pet.json"))
let theme = PetThemeStore.loadTheme(folder: template, isBuiltIn: false)!
check(PetSharing.validate(theme).isEmpty, "Starter must pass validation")
check(theme.imageURL(for: .celebrating) == theme.url(forSlot: .idle), "Missing pose must fall back")
let zip = root.appendingPathComponent("roundtrip.zip")
try PetSharing.export(theme, to: zip)
let library = PetCatalog(userPetsDirectory: root.appendingPathComponent("library"))
let installed = try library.installZIP(at: zip)
check(installed.displayName == theme.displayName && installed.isNSFW, "Name and NSFW must survive import")
check(PetSharing.manifest(at: installed.folderURL)["author"] as? String == "测试创作者", "Author must survive import")
let installedPNG = try Data(contentsOf: installed.url(forSlot: .idle)!)
let originalPNG = try Data(contentsOf: theme.url(forSlot: .idle)!)
check(installedPNG == originalPNG, "Pixels must survive round trip")
check(fm.fileExists(atPath: installed.folderURL.appendingPathComponent("preview.png").path), "Preview must be packaged")
let draft = library.makeDraft(editing: installed)!
var editedMetadata = PetMetadata(manifest: PetSharing.manifest(at: draft.draftURL))
editedMetadata.version = "1.1.0"
let edited = library.install(draftAt: draft.draftURL, name: "我的蓝点", replacing: installed.id, metadata: editedMetadata)!
check(edited.id == installed.id && edited.isNSFW, "Editing preserves identity and flags")
try PetSharing.export(edited, to: zip)
let secondLibrary = PetCatalog(userPetsDirectory: root.appendingPathComponent("second-library"))
let second = try secondLibrary.installZIP(at: zip)
check(second.displayName == "我的蓝点", "Edited title must survive re-export")
check(PetSharing.manifest(at: second.folderURL)["version"] as? String == "1.1.0", "Edited version must survive re-export")
let badDraft = library.makeDraft(editing: edited)!
try Data("broken png".utf8).write(to: badDraft.draftURL.appendingPathComponent("idle.png"))
check(library.install(draftAt: badDraft.draftURL, name: "破损", replacing: edited.id) == nil, "Invalid draft must not install")
check(fm.fileExists(atPath: edited.url(forSlot: .idle)!.path), "Failed save must preserve original")
library.discardDraft(badDraft.draftURL)
let invalid = root.appendingPathComponent("invalid.zip")
try Data("not a zip".utf8).write(to: invalid)
do { _ = try library.installZIP(at: invalid); fatalError("Invalid ZIP accepted") } catch { checks += 1 }
// A symlink image must never be included in an exported package.
let linked = root.appendingPathComponent("linked")
try fm.createDirectory(at: linked, withIntermediateDirectories: true)
try fm.createSymbolicLink(at: linked.appendingPathComponent("idle.png"), withDestinationURL: theme.url(forSlot: .idle)!)
check(PetSharing.validate(PetThemeStore.loadTheme(folder: linked, isBuiltIn: false)!).contains(where: \.blocking), "Symlink must be blocked")
check(ReleaseVersion("v1.10.0")! > ReleaseVersion("1.2.9")!, "Semver must compare numerically")
check(ReleaseVersion("1.2") == nil && ReleaseVersion("1.2.0-beta") == nil, "Only stable semver accepted")
check(ReleaseVersion("-1.2.0") == nil, "Negative versions invalid")
if CommandLine.arguments.count > 1 {
    let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
    for name in ["traversal", "duplicate", "multiple", "oversize", "image-limit"] {
        do {
            _ = try library.installZIP(at: fixtures.appendingPathComponent(name + ".zip"))
            fatalError("Unsafe ZIP accepted: \(name)")
        } catch { checks += 1 }
    }
}
print("PASS: \(checks) native ecosystem checks (pet export/import/edit/rollback, metadata, invalid files, release versions)")
