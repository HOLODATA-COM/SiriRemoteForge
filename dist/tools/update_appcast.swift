#!/usr/bin/swift
import Foundation

enum AppcastError: Error, CustomStringConvertible {
    case usage
    case missingMarker(String)
    case unreadableNotes

    var description: String {
        switch self {
        case .usage:
            return "usage: update_appcast.swift APPCAST VERSION BUILD PKG SIGNATURE LENGTH NOTES CHANNEL PUBDATE"
        case .missingMarker(let marker):
            return "appcast is missing marker: \(marker)"
        case .unreadableNotes:
            return "release notes are not valid UTF-8"
        }
    }
}

func xmlEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

do {
    guard CommandLine.arguments.count == 10 else { throw AppcastError.usage }
    let appcastURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let version = CommandLine.arguments[2]
    let build = CommandLine.arguments[3]
    let packageName = CommandLine.arguments[4]
    let signature = CommandLine.arguments[5]
    let length = CommandLine.arguments[6]
    let notesURL = URL(fileURLWithPath: CommandLine.arguments[7])
    let channel = CommandLine.arguments[8]
    let pubDate = CommandLine.arguments[9]

    guard let notes = String(data: try Data(contentsOf: notesURL), encoding: .utf8) else {
        throw AppcastError.unreadableNotes
    }
    // Split the only sequence forbidden inside CDATA without altering rendered Markdown.
    let safeNotes = notes.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>")
    let encodedVersion = xmlEscape(version)
    let packageURL = "https://github.com/HOLODATA-COM/SiriRemoteForge/releases/download/v\(encodedVersion)/\(xmlEscape(packageName))"
    let releaseURL = "https://github.com/HOLODATA-COM/SiriRemoteForge/releases/tag/v\(encodedVersion)"
    let channelElement = channel == "stable"
        ? ""
        : "\n            <sparkle:channel>\(xmlEscape(channel))</sparkle:channel>"
    let item = """

        <item>
            <title>HyperVibe \(encodedVersion)</title>
            <link>\(releaseURL)</link>
            <pubDate>\(xmlEscape(pubDate))</pubDate>
            <sparkle:version>\(xmlEscape(build))</sparkle:version>
            <sparkle:shortVersionString>\(encodedVersion)</sparkle:shortVersionString>\(channelElement)
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
            <description sparkle:format="markdown"><![CDATA[
    \(safeNotes)
            ]]></description>
            <enclosure url="\(packageURL)"
                       length="\(xmlEscape(length))"
                       type="application/octet-stream"
                       sparkle:edSignature="\(xmlEscape(signature))" />
        </item>
    """

    var appcast = try String(contentsOf: appcastURL, encoding: .utf8)
    // Editing invalidates the previous whole-feed signature. Remove it before asking sign_update
    // to append a new one; the permanent warning comment is intentionally retained.
    appcast = appcast.replacingOccurrences(
        of: #"(?s)\s*<!--\s*sparkle-signatures:.*?-->\s*$"#,
        with: "\n",
        options: .regularExpression
    )

    let startMarker = "<!-- hypervibe:\(channel):start -->"
    let endMarker = "<!-- hypervibe:\(channel):end -->"
    guard let start = appcast.range(of: startMarker) else {
        throw AppcastError.missingMarker(startMarker)
    }
    guard let end = appcast.range(of: endMarker, range: start.upperBound..<appcast.endIndex) else {
        throw AppcastError.missingMarker(endMarker)
    }
    appcast.replaceSubrange(start.upperBound..<end.lowerBound, with: item + "\n        ")
    try appcast.write(to: appcastURL, atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
}
