//
//  library_wrapper.swift
//  sourcekitten
//
//  Created by Norio Nomura on 2/20/16.
//  Copyright © 2016 SourceKitten. All rights reserved.
//

// This code originates from the SourceKitten tool which carries the following license:
// The MIT License (MIT)
//
// Copyright (c) 2014 JP Simard.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Foundation

struct DynamicLinkLibrary {
    let path: String
    let handle: UnsafeMutableRawPointer

    func load<T>(symbol: String) -> T {
        guard let sym = dlsym(handle, symbol) else {
            let errorString = String(validatingUTF8: dlerror()) ?? "DynamicLinkLibrary Unknown Error"
            fatalError("Finding symbl \(symbol) failed: \(errorString)")
        }
        return unsafeBitCast(sym, to: T.self)
    }
}

#if os(Linux)
let toolchainLoader = Loader(searchPaths: [linuxSourceKitLibPath])
#else
let toolchainLoader = Loader(searchPaths: [
    xcodeDefaultToolchainOverride,
    toolchainDir,
    xcrunFindPath,
    /*
    These search paths are used when `xcode-select -p` points to
    "Command Line Tools OS X for Xcode", but Xcode.app exists.
    */
    applicationsDir?.xcodeDeveloperDir.toolchainDir,
    applicationsDir?.xcodeBetaDeveloperDir.toolchainDir,
    userApplicationsDir?.xcodeDeveloperDir.toolchainDir,
    userApplicationsDir?.xcodeBetaDeveloperDir.toolchainDir,
].flatMap { path in
    if let fullPath = path?.usrLibDir, fullPath.isFile {
        return fullPath
    }
    return nil
})
#endif

struct Loader {
    let searchPaths: [String]

    func load(path: String) -> DynamicLinkLibrary {
        let fullPaths = searchPaths.map { $0.appending(pathComponent: path) }.filter { $0.isFile }

        // try all fullPaths that contains target file,
        // then try loading with simple path that depends resolving to DYLD
        for fullPath in fullPaths + [path] {
            if let handle = dlopen(fullPath, RTLD_LAZY) {
                return DynamicLinkLibrary(path: path, handle: handle)
            }
        }

        fatalError("Loading \(path) failed")
    }
}

private func env(_ name: String) -> String? {
    return ProcessInfo.processInfo.environment[name]
}

/// Returns "LINUX_SOURCEKIT_LIB_PATH" environment variable,
/// or "/usr/lib" if unspecified.
internal let linuxSourceKitLibPath = env("LINUX_SOURCEKIT_LIB_PATH") ?? "/usr/lib"

/// Returns "XCODE_DEFAULT_TOOLCHAIN_OVERRIDE" environment variable
///
/// `launch-with-toolchain` sets the toolchain path to the
/// "XCODE_DEFAULT_TOOLCHAIN_OVERRIDE" environment variable.
private let xcodeDefaultToolchainOverride = env("XCODE_DEFAULT_TOOLCHAIN_OVERRIDE")

/// Returns "TOOLCHAIN_DIR" environment variable
///
/// `Xcode`/`xcodebuild` sets the toolchain path to the
/// "TOOLCHAIN_DIR" environment variable.
private let toolchainDir = env("TOOLCHAIN_DIR")

/// Returns toolchain directory that parsed from result of `xcrun -find swift`
///
/// This is affected by "DEVELOPER_DIR", "TOOLCHAINS" environment variables.
private let xcrunFindPath: String? = {
    let pathOfXcrun = "/usr/bin/xcrun"

    if !FileManager.default.isExecutableFile(atPath: pathOfXcrun) {
        return nil
    }

    let task = Process()
    task.launchPath = pathOfXcrun
    task.arguments = ["-find", "swift"]

    let pipe = Pipe()
    task.standardOutput = pipe
    task.launch() // if xcode-select does not exist, crash with `NSInvalidArgumentException`.

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else {
        return nil
    }

    var start = output.startIndex
    var end = output.startIndex
    var contentsEnd = output.startIndex
    output.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: start..<start)
    let xcrunFindSwiftPath = output.substring(with: start..<contentsEnd)
    guard xcrunFindSwiftPath.hasSuffix("/usr/bin/swift") else {
        return nil
    }
    let xcrunFindPath = xcrunFindSwiftPath.deleting(lastPathComponents: 3)
    // Return nil if xcrunFindPath points to "Command Line Tools OS X for Xcode"
    // because it doesn't contain `sourcekitd.framework`.
    if xcrunFindPath == "/Library/Developer/CommandLineTools" {
        return nil
    }
    return xcrunFindPath
}()

private let applicationsDir: String? =
    NSSearchPathForDirectoriesInDomains(.applicationDirectory, .systemDomainMask, true).first

private let userApplicationsDir: String? =
    NSSearchPathForDirectoriesInDomains(.applicationDirectory, .userDomainMask, true).first

private extension String {
    var toolchainDir: String {
        return appending(pathComponent: "Toolchains/XcodeDefault.xctoolchain")
    }

    var xcodeDeveloperDir: String {
        return appending(pathComponent: "Xcode.app/Contents/Developer")
    }

    var xcodeBetaDeveloperDir: String {
        return appending(pathComponent: "Xcode-beta.app/Contents/Developer")
    }

    var usrLibDir: String {
        return appending(pathComponent: "/usr/lib")
    }

    func appending(pathComponent: String) -> String {
        return URL(fileURLWithPath: self).appendingPathComponent(pathComponent).path
    }

    func deleting(lastPathComponents numberOfPathComponents: Int) -> String {
        var url = URL(fileURLWithPath: self)
        for _ in 0..<numberOfPathComponents {
            url = url.deletingLastPathComponent()
        }
        return url.path
    }
}
