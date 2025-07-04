import Foundation
import System
import MachO
import mach
import CoreServices
import AppKit

import ArgumentParser
import Rainbow


struct CPUType: Decodable {
    let value: cpu_type_t
    let name: String
}

struct FatFile {
    let url: URL
    let size: Int64
    let archs: [fat_arch]
}

nonisolated(unsafe) let sizeFormatter: ByteCountFormatter = {
    let sizeFormatter = ByteCountFormatter()
    sizeFormatter.countStyle = .file
    return sizeFormatter
}()

@main
struct AppThinner: ParsableCommand {
    static let configuration: CommandConfiguration = .init(
        abstract: "Search for fat binaries. Remove unused framework versions and other architectures to free up disk space.",
        version: "0.1.0"
    )

    @Flag(help: "Remove unused framework versions")
    var removeUnusedFrameworkVersions = false

    @Flag(help: "Search apps and group items; it's slower, but better.")
    var appsOnly = false

    @Flag(help: "Force strip never used apps.")
    var forceStripNeverUsedApps = false

    @Flag(help: "Do everything except actually running the commands")
    var dryRun = false

    @Argument(help: "Directory to search(default: /Applications)", completion: .directory)
    var searchDirectory: String = "/Applications"

    private var cpuType: CPUType = .init(value: 0, name: "unknown")

    mutating func run() throws {
        cpuType = detectCPUType()

        var totalSaved: Int64 = 0
        if appsOnly {
            print("Searching apps...")
            let apps = searchApps(at: searchDirectory)
            for app in apps {
                totalSaved += processFiles(at: app)
            }
        } else {
            print("Search and strip fat binaries...")
            totalSaved = processFiles(at: .init(fileURLWithPath: searchDirectory))
        }

        if totalSaved > 0 {
            let message = "Totally saved you \(sizeFormatter.string(fromByteCount: totalSaved))"
            print(String(repeating: "-", count: message.count))
            print(message.lightGreen.bold)
        }
    }

    func processFiles(at path: URL) -> Int64 {
        let resourceValues = try? path.resourceValues(forKeys: [.localizedNameKey, .isApplicationKey])
        let appName = resourceValues?.localizedName ?? path.lastPathComponent
        let originalSize = calculateSize(for: path)
        if !forceStripNeverUsedApps
            && resourceValues?.isApplication == true
            && lastUsedDate(for: path) == nil {
            print("It seems that you have never used \(appName) before, skipped.".yellow)
            return 0
        }

        if appsOnly {
            print("Search fat binaries for: \(appName)...")
        }
        let (fatBinaries, frameworks) = searchFatBinaries(at: path)

        if appsOnly && !fatBinaries.isEmpty {
            let runningApps: [URL: NSRunningApplication] = NSWorkspace.shared.runningApplications
                .reduce(into: [:]) { partialResult, app in
                    guard let url = app.bundleURL else {
                        return
                    }
                    partialResult[url] = app
                }
            if let app = runningApps[path] {
                print("\(appName.bold) is running, do you want to kill it(y/n)?".lightMagenta)
                let answer = readLine()
                if answer?.lowercased() == "y" {
                    app.terminate()
                }
            }
        }

        var savedSize: Int64 = 0
        for binary in fatBinaries {
            let (beforeSize, afterSize) = stripBinary(fatFile: binary)
            let before = sizeFormatter.string(fromByteCount: beforeSize)
            let after = sizeFormatter.string(fromByteCount: afterSize)
            print("\(binary.url.path(percentEncoded: false)) (\(before) → \(after))".green)
            savedSize += beforeSize - afterSize
        }

        for framework in frameworks {
            savedSize += removeUnusedFrameworkVersions(framework)
        }

        if savedSize > 0 {
            let before = sizeFormatter.string(fromByteCount: originalSize)
            let after = sizeFormatter.string(fromByteCount: calculateSize(for: path))
            print("Saved you \(sizeFormatter.string(fromByteCount: savedSize)) for \(appName) (\(before) → \(after))".green.bold)
        }

        return savedSize
    }

    func detectCPUType() -> CPUType {
        var size = 0
        var cpuType: Int32 = 0
        let sysctlName = "hw.cputype"
        if sysctlbyname(sysctlName, nil, &size, nil, 0) == noErr && size > 0 {
            sysctlbyname(sysctlName, &cpuType, &size, nil, 0)
        }

        var utsname = utsname()
        let machine: String = if uname(&utsname) == noErr {
            withUnsafePointer(to: utsname.machine) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(cString: $0)
                }
            }
        } else {
            "unknown"
        }

        return .init(value: cpu_type_t(cpuType), name: machine)
    }

    func searchApps(at path: String) -> [URL] {
        let pathURL = URL(fileURLWithPath: path)
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isApplicationKey,
            .isWritableKey,
            .isDirectoryKey,
            .localizedNameKey
        ]

        guard let enumerator = fm.enumerator(at: pathURL, includingPropertiesForKeys: keys) else {
            return []
        }

        var apps: [URL] = []
        for case let url as URL in enumerator {
            let resouceValues = try? url.resourceValues(forKeys: Set(keys))
            guard resouceValues?.isApplication == true
                    && resouceValues?.isWritable == true
                    && resouceValues?.isDirectory == true else {
                continue
            }

            apps.append(url)
        }
        return apps.filter {
            guard let filePath = FilePath($0) else { return false }
            return filePath.components.count(where: { $0.extension == "app" }) == 1
        }
    }

    func searchFatBinaries(at url: URL) -> (fatBinaries: [FatFile], frameworks: [URL]) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isExecutableKey,
            .isWritableKey,
            .isRegularFileKey,
            .fileSizeKey,
            .isApplicationKey
        ]
        let fatHeaders: Set<UInt32> = [
            FAT_CIGAM_64,
            FAT_MAGIC_64,
            FAT_CIGAM,
            FAT_MAGIC
        ]

        var fatBinaries: [FatFile] = []
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return ([], [])
        }

        var frameworks: [URL] = []
        for case let url as URL in enumerator {
            do {
                let resourceValues = try url.resourceValues(forKeys: .init(keys))
                guard resourceValues.isWritable == true else {
                    continue
                }

                if removeUnusedFrameworkVersions, resourceValues.isDirectory == true {
                    if url.pathExtension == "framework" {
                        frameworks.append(url)
                    }
                }
                
                if resourceValues.isExecutable == true && resourceValues.isRegularFile == true {
                    let fh = try FileHandle(forReadingFrom: url)
                    defer { try? fh.close() }

                    if let data = try fh.read(upToCount: 4) {
                        let header = data.withUnsafeBytes {
                            $0.load(as: UInt32.self)
                        }
                        if fatHeaders.contains(header) {
                            try fh.seek(toOffset: 0)
                            let fatHeaderSize = MemoryLayout<fat_header>.size
                            if let headerData = try fh.read(upToCount: fatHeaderSize) {
                                let header = headerData.withUnsafeBytes {
                                    $0.load(as: fat_header.self)
                                }
                                let numOfArchs = Int(header.nfat_arch.bigEndian)
                                if numOfArchs > 1 {
                                    let archSize = MemoryLayout<fat_arch>.size
                                    let archsSize = numOfArchs * archSize
                                    if let archsData = try fh.read(upToCount: archsSize) {
                                        let archs = archsData.withUnsafeBytes {
                                            var results: [fat_arch] = []
                                            for i in 0..<numOfArchs {
                                                results.append($0.load(fromByteOffset: i * archSize, as: fat_arch.self))
                                            }
                                            return results
                                        }
                                        if archs.has(cpuType) {
                                            fatBinaries.append(.init(
                                                url: url,
                                                size: Int64(resourceValues.fileSize ?? 0),
                                                archs: archs
                                            ))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } catch {
                if let errorData = "Search fat binary error: \(error.localizedDescription)\n".red.data(using: .utf8) {
                    try? FileHandle.standardError
                        .write(contentsOf: errorData)
                }
            }
        }

        return (fatBinaries, frameworks)
    }

    func calculateSize(for appURL: URL) -> Int64 {
        let fm = FileManager.default
        do {
            let resourceValues = try appURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isRegularFileKey])

            guard resourceValues.isDirectory == true else {
                if resourceValues.isRegularFile == true {
                    return Int64(resourceValues.fileSize ?? 0)
                }
                return 0
            }

            let keys: [URLResourceKey] = [
                .isRegularFileKey,
                .fileSizeKey
            ]
            guard let enumerator = fm.enumerator(at: appURL, includingPropertiesForKeys: keys) else {
                return 0
            }

            var totalSize: Int64 = 0
            for case let url as URL in enumerator {
                guard let resourceValues = try? url.resourceValues(forKeys: Set(keys)),
                      resourceValues.isRegularFile == true else {
                    continue
                }

                totalSize += Int64(resourceValues.fileSize ?? 0)
            }
            return totalSize
        } catch {
            return 0
        }
    }

    func lastUsedDate(for app: URL) -> Date? {
        guard let item = MDItemCreate(nil, app.path(percentEncoded: false) as CFString) else {
            return nil
        }

        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    func stripBinary(fatFile: FatFile) -> (Int64, Int64) {
        do {
            guard let arch = fatFile.archs.arch(for: cpuType) else {
                return (fatFile.size, 0)
            }

            guard !dryRun else {
                return (fatFile.size, Int64(arch.size.bigEndian))
            }

            let fh = try FileHandle(forUpdating: fatFile.url)
            defer {
                try? fh.close()
            }

            let offset = UInt64(arch.offset.bigEndian)
            let size = Int(arch.size.bigEndian)
            try fh.seek(toOffset: offset)
            guard let data = try fh.read(upToCount: size), data.count == size else {
                return (fatFile.size, 0)
            }

            try fh.truncate(atOffset: 0)
            try fh.write(contentsOf: data)

            return (fatFile.size, Int64(size))
        } catch {
            if let errorData = "Strip binary error: \(error.localizedDescription)".red.data(using: .utf8) {
                try? FileHandle.standardError
                    .write(contentsOf: errorData)
            }
            return (fatFile.size, 0)
        }
    }

    func removeUnusedFrameworkVersions(_ frameworkURL: URL) -> Int64 {
        let versionsURL = frameworkURL.appending(path: "Versions")
        let fm = FileManager.default
        do {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: versionsURL.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue else {
                return 0
            }

            let urls = try fm.contentsOfDirectory(at: versionsURL, includingPropertiesForKeys: [.isSymbolicLinkKey])
            var preserveURLs: Set<URL> = []
            for url in urls {
                let resouceValues = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
                if resouceValues.isSymbolicLink == true {
                    preserveURLs.insert(url)
                    preserveURLs.insert(url.resolvingSymlinksInPath())
                }
            }

            guard !preserveURLs.isEmpty else { return 0}

            let urlsToRemove = urls.filter { !preserveURLs.contains($0) }
            guard !urlsToRemove.isEmpty else {
                return 0
            }

            var removedSize: Int64 = 0
            for url in urlsToRemove {
                let size = calculateSize(for: url)
                let readableSize = sizeFormatter.string(fromByteCount: size)
                print("Removing unused framework version: \(url.lastPathComponent.bold) (\(readableSize)) in \(frameworkURL.path(percentEncoded: false))".red)
                try fm.removeItem(at: url)
                removedSize += size
            }

            return removedSize
        } catch {
            if let errorData = "Remove unused framework versions error: \(error.localizedDescription)\n".red.data(using: .utf8) {
                try? FileHandle.standardError
                    .write(contentsOf: errorData)
            }
            return 0
        }
    }
}

extension [fat_arch] {
    func has(_ cpuType: CPUType) -> Bool {
        contains { fat_arch in
            fat_arch.cputype.bigEndian == cpuType.value
        }
    }

    func arch(for cpuType: CPUType) -> fat_arch? {
        first {
            $0.cputype.bigEndian == cpuType.value
        }
    }
}
