#!/usr/bin/env swift
import Foundation

// --- Helper Functions ---

// Represents the final chapter data we need
struct ChapterInfo {
    var title: String
    var startTime: Double // in seconds
}

// Codable structs matching ffprobe JSON output
struct FFProbeOutput: Codable {
    let chapters: [FFProbeChapter]
}

struct FFProbeChapter: Codable {
    let id: Int
    let timeBase: String // e.g., "1/1000"
    let start: Int // Start time in time_base units
    let startTime: String // Start time as decimal string "0.000000"
    let end: Int // End time in time_base units
    let endTime: String // End time as decimal string "12.345000"
    let tags: FFProbeTags?
    
    // Use CodingKeys to map snake_case JSON keys to camelCase Swift properties
    enum CodingKeys: String, CodingKey {
        case id
        case timeBase = "time_base"
        case start
        case startTime = "start_time"
        case end
        case endTime = "end_time"
        case tags
    }
}

struct FFProbeTags: Codable {
    let title: String?
}

// Function to run a command line process
func runProcess(executableURL: URL, arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    process.waitUntilExit()

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

    let output = String(data: outputData, encoding: .utf8) ?? ""
    let error = String(data: errorData, encoding: .utf8) ?? ""

    return (process.terminationStatus, output, error)
}

// Helper function to find an executable using 'which' via /usr/bin/env
func findExecutable(named executableName: String) -> URL? {
    let envURL = URL(fileURLWithPath: "/usr/bin/env")

    guard FileManager.default.fileExists(atPath: envURL.path) else {
        print("Error: /usr/bin/env not found. Cannot search for executables.")
        return nil
    }

    do {
        let (status, stdout, stderr) = try runProcess(executableURL: envURL, arguments: ["which", executableName])
        
        if status == 0 {
            let path = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            // Double-check that the path is not empty and the file exists
            if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            } else {
                 print("  'env which \(executableName)' returned invalid path or file not found: '\(path)'")
            }
        } else {
            // Log stderr from 'which' if it failed
            let errorMsg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            print("  'env which \(executableName)' failed (Status: \(status)). \(errorMsg.isEmpty ? "" : "Stderr: \(errorMsg)")")
        }
    } catch {
        print("  Error running '/usr/bin/env which \(executableName)': \(error)")
    }

    print("Error: Could not find executable '\(executableName)'. Please ensure it is installed and in your PATH.")
    return nil
}

// Removes characters potentially problematic for filenames
func sanitizeFilename(_ filename: String) -> String {
    var sanitized = filename

    // 1. Trim leading/trailing whitespace
    sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)

    // 2. Define problematic characters (add any others as needed)
    // Includes: Path separators, common invalid chars, control chars, smart quotes
    let invalidCharacters = CharacterSet(charactersIn: "/:'\"<>|?*&%$!@^`~\u{0}") // Use \u{0} for null char
                                .union(.controlCharacters)
                                .union(CharacterSet(charactersIn: "“”‘’")) // Use actual smart quotes

    // 3. Remove problematic characters
    sanitized = sanitized.components(separatedBy: invalidCharacters).joined(separator: "_") // Replace with underscore

    // 4. Replace multiple consecutive underscores with a single one
    while sanitized.contains("__") {
        sanitized = sanitized.replacingOccurrences(of: "__", with: "_")
    }

    // 5. Remove leading/trailing underscores that might result from replacement
    sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "_"))

    // 6. Handle case where the entire filename becomes empty or just underscores
    if sanitized.isEmpty || sanitized == "_" {
        // Fallback to a generic name or timestamp
        return "Untitled_Chapter_\(UUID().uuidString.prefix(8))"
    }
    
    // 7. Optional: Limit filename length (macOS limit is typically 255 bytes)
    let maxLength = 200 // Be conservative
    if sanitized.utf8.count > maxLength { // Check byte count for underlying OS limit
        // Use prefix based on character count (grapheme clusters) for simpler truncation
        // This might slightly exceed byte limit if multi-byte chars are near the end, but is safer for user-visible strings
        let truncated = String(sanitized.prefix(maxLength))
        // Re-trim potentially reintroduced whitespace/underscores if cut happened there
        sanitized = truncated.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "_")))
         // Ensure it didn't become empty after re-trimming
        if sanitized.isEmpty {
             return "Untitled_Chapter_\(UUID().uuidString.prefix(8))" // Fallback again
        }
    }

    return sanitized
}

// --- Main Script Logic ---

// 1. Check Arguments
guard CommandLine.arguments.count == 2 else {
    print("Usage: \(CommandLine.arguments[0]) <input_file.m4b>")
    exit(1)
}
let inputFilePath = CommandLine.arguments[1]
let inputFileURL = URL(fileURLWithPath: inputFilePath)

// Check if input file exists
guard FileManager.default.fileExists(atPath: inputFilePath) else {
    print("Error: Input file not found at '\(inputFilePath)'")
    exit(1)
}

// 2. Define Paths & Find Executables
let outputDirectoryName = "output"
let outputDirectoryURL = URL(fileURLWithPath: outputDirectoryName)

print("Resolving dependencies...")
// Find ffmpeg and ffprobe dynamically
guard let ffmpegURL = findExecutable(named: "ffmpeg") else {
    // Error message printed within findExecutable
    exit(1)
}
print("  ffmpeg:  \(ffmpegURL.path())")

guard let ffprobeURL = findExecutable(named: "ffprobe") else {
    // Error message printed within findExecutable
    exit(1)
}
print("  ffprobe: \(ffprobeURL.path())")

// 3. Create Output Directory
do {
    try FileManager.default.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true, attributes: nil)
    print("Output directory created/ensured at '\(outputDirectoryName)'")
} catch {
    print("Error: Could not create output directory '\(outputDirectoryName)': \(error)")
    exit(1)
}

// 4. Extract Metadata using ffprobe (JSON output)
print("Extracting chapter metadata from '\(inputFilePath)'...")
var chapterJSONData: Data?
do {
    // Arguments for ffprobe to output chapters as JSON
    let args = [
        "-v", "error",             // Suppress informational messages
        "-show_chapters",       // Request chapter information
        "-print_format", "json", // Output in JSON format
        inputFilePath
    ]
    let (status, stdout, stderr) = try runProcess(executableURL: ffprobeURL, arguments: args)

    if status != 0 {
        print("Error: ffprobe failed to extract metadata (Exit Code: \(status)).")
        print("ffprobe stderr:\n\(stderr)")
        exit(1)
    }
    
    // Store the JSON output data
    guard let jsonData = stdout.data(using: .utf8) else {
        print("Error: Could not convert ffprobe output to Data.")
        print("ffprobe stdout:\n\(stdout)")
        exit(1)
    }
    chapterJSONData = jsonData

} catch {
    print("Error: Failed to run ffprobe for metadata extraction: \(error)")
    exit(1)
}

// 5. Read and Parse Metadata (Now using JSONDecoder)
var chapters: [ChapterInfo] = []

guard let jsonData = chapterJSONData else 
{
    print("Error: Chapter JSON data was not available for parsing.")
    exit(1)
}

do {
    let decoder = JSONDecoder()
    let ffprobeOutput = try decoder.decode(FFProbeOutput.self, from: jsonData)
    
    // Map FFProbeChapter to ChapterInfo
    var chapterIndex = 0 // For generating default titles
    chapters = ffprobeOutput.chapters.compactMap { ffprobeChapter in
        let startTimeDouble: Double?
        
        // Try parsing the precise start_time string first
        if let parsedTime = Double(ffprobeChapter.startTime) {
            startTimeDouble = parsedTime
        } else {
            // Fallback: Try calculating from start and time_base
            print("Warning: Could not parse start_time string '\(ffprobeChapter.startTime)' for chapter ID \(ffprobeChapter.id). Attempting fallback calculation.")
            let tbComponents = ffprobeChapter.timeBase.split(separator: "/")
            if tbComponents.count == 2,
                let num = Double(tbComponents[0]),
                let den = Double(tbComponents[1]), den != 0 {
                startTimeDouble = Double(ffprobeChapter.start) * num / den
            } else {
                // Could not determine start time, skip this chapter
                print("Error: Could not parse time_base '\(ffprobeChapter.timeBase)' or start value '\(ffprobeChapter.start)' for chapter ID \(ffprobeChapter.id) during fallback. Skipping chapter.")
                startTimeDouble = nil // Indicate failure
            }
        }
        
        // Ensure we have a valid start time before proceeding
        guard let finalStartTime = startTimeDouble else {
            return nil // Skip chapter if time determination failed
        }
        
        // Determine the chapter title (use default if missing/empty)
        let finalTitle: String
        if let title = ffprobeChapter.tags?.title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            finalTitle = title
        } else {
            chapterIndex += 1
            finalTitle = String(format: "Chapter_%02d", chapterIndex)
            print("Warning: Chapter ID \(ffprobeChapter.id) found with missing title. Using default: '\(finalTitle)'")
        }
        
        // Create and return the ChapterInfo object
        return ChapterInfo(title: finalTitle, startTime: finalStartTime)
    }
    
    // Sort chapters by start time just in case ffprobe output is not ordered
    chapters.sort { $0.startTime < $1.startTime }

} catch {
    print("Error: Failed to decode chapter JSON: \(error)")
    // Print the JSON data for debugging if decoding fails
    if let jsonString = String(data: jsonData, encoding: .utf8) {
            print("--- JSON Data Start ---")
            print(jsonString)
            print("--- JSON Data End ---")
    }
    exit(1)
}

guard !chapters.isEmpty else {
     print("Error: No chapters parsed from metadata. Does the input file have chapters?")
     exit(1)
}

print("Found \(chapters.count) chapters.")

// 6. Split Chapters using ffmpeg
print("Splitting chapters...")
for i in 0..<chapters.count {
    let chapter = chapters[i]
    let chapterNumber = i + 1
    let sanitizedTitle = sanitizeFilename(chapter.title)
    let filenamePrefix = String(format: "%02d", chapterNumber)
    let outputFilename = "\(filenamePrefix)_\(sanitizedTitle).m4b"
    let outputFileURL = outputDirectoryURL.appendingPathComponent(outputFilename)

    var ffmpegSplitArgs = [
        "-nostdin",
        "-i", inputFilePath,
        "-ss", String(format: "%.6f", chapter.startTime) // Use chapter.startTime
    ]

    // Add end time (-to) if it's not the last chapter
    if i < chapters.count - 1 {
        let nextChapter = chapters[i + 1]
        ffmpegSplitArgs.append("-to")
        ffmpegSplitArgs.append(String(format: "%.6f", nextChapter.startTime)) // Use nextChapter.startTime
    }
    // Else, ffmpeg copies to the end of the file by default

    ffmpegSplitArgs.append(contentsOf: [
        "-c", "copy",           // Copy codecs without re-encoding
        "-map_metadata", "0",   // Copy global metadata
        "-vn",                  // Exclude video stream if present
        outputFileURL.path
    ])

    let chapterProgress = " [-] [\(chapterNumber)/\(chapters.count)]  '\(chapter.title)' to '\(outputFilename)'..."
    // print chapterProgress without a newline
    print(chapterProgress, terminator: "")

    do {
        let (status, _, stderr) = try runProcess(executableURL: ffmpegURL, arguments: ffmpegSplitArgs)
        if status != 0 {
            print("    Error: ffmpeg failed to extract chapter \(chapterNumber) (Exit Code: \(status)).")
            print("    ffmpeg stderr:\n\(stderr)")
            // Optional: Decide whether to continue or exit on chapter error
        } else {
             // go back the bumber of characters in chapterProgress
             // print a green checkmark
             print("\u{1b}[\(chapterProgress.count - 2)D\u{001b}[32m✔︎\u{001b}[0m")
        }
    } catch {
        // go back the bumber of characters in chapterProgress
        // print a red x
        print("\u{1b}[\(chapterProgress.count - 2)D\u{001b}[31m✗\u{001b}[0m")
        print("    Error: Failed to run ffmpeg for chapter \(chapterNumber): \(error)")
        // Optional: Decide whether to continue or exit on chapter error
    }
}

print("Chapter splitting complete. Output files are in '\(outputDirectoryName)/'")
exit(0) 