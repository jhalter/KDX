import Foundation
import KDXClientUI

@main enum KDXAppearanceTool {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.count == 3, arguments[0] == "export" {
                try await ClassicBundledAppearances.export(from:URL(fileURLWithPath:arguments[1]),to:URL(fileURLWithPath:arguments[2]))
                print("Exported all 16 original appearances with artwork and fonts.")
            } else if arguments.count == 2, arguments[0] == "verify" {
                let appearances = try ClassicBundledAppearances.load(from:URL(fileURLWithPath:arguments[1]))
                print("Verified \(appearances.count) bundled appearances.")
            } else {
                throw AppearanceError.invalid("Usage: KDXAppearanceTool export ORIGINAL_APP_OR_ARCHIVE OUTPUT_JSON | verify CATALOG_JSON")
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8))
            exit(1)
        }
    }
}
