#!/usr/bin/env swift
import Foundation

// --- Helper Functions ---

// Represents chapter information for the final audiobook
struct ChapterInfo {
    var title: String
    var startTime: Double // in seconds
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

// Function to get duration of an audio file using ffprobe
func getAudioDuration(fileURL: URL, ffprobeURL: URL) throws -> Double {
    let args = [
        "-v", "error",
        "-show_entries", "format=duration",
        "-of", "csv=p=0",
        fileURL.path
    ]
    
    let (status, stdout, stderr) = try runProcess(executableURL: ffprobeURL, arguments: args)
    
    if status != 0 {
        throw NSError(domain: "ChapterJoin", code: 1, userInfo: [NSLocalizedDescriptionKey: "ffprobe failed to get duration: \(stderr)"])
    }
    
    guard let duration = Double(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw NSError(domain: "ChapterJoin", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not parse duration from ffprobe output: \(stdout)"])
    }
    
    return duration
}

// Function to create a temporary file list for ffmpeg concat protocol (fast!)
func createConcatFileList(inputFiles: [URL]) throws -> URL {
    let tempDir = FileManager.default.temporaryDirectory
    let concatFileURL = tempDir.appendingPathComponent("chapter_join_\(UUID().uuidString).txt")
    
    let fileListContent = inputFiles.map { "file '\($0.path)'" }.joined(separator: "\n")
    
    try fileListContent.write(to: concatFileURL, atomically: true, encoding: .utf8)
    
    return concatFileURL
}

// Function to create chapter metadata file for ffmpeg
func createChapterMetadata(chapters: [ChapterInfo], totalDurationSeconds: Double) throws -> URL {
    let tempDir = FileManager.default.temporaryDirectory
    let metadataFileURL = tempDir.appendingPathComponent("chapter_metadata_\(UUID().uuidString).txt")
    
    let metadataContent = createChapterMetadataContent(chapters: chapters, totalDurationSeconds: totalDurationSeconds)
    try metadataContent.write(to: metadataFileURL, atomically: true, encoding: .utf8)
    
    return metadataFileURL
}

// Function to create chapter metadata content
func createChapterMetadataContent(chapters: [ChapterInfo], totalDurationSeconds: Double) -> String {
    var metadataContent = "FFMETADATA1\n"
    for (index, chapter) in chapters.enumerated() {
        metadataContent += "[CHAPTER]\n"
        metadataContent += "TIMEBASE=1/1000\n"
        metadataContent += "START=\(Int(chapter.startTime * 1000))\n"
        
        // Calculate end time - use next chapter's start time or a large number for the last chapter
        let endTime: Int = {
            if index < chapters.count - 1 {
                return Int(chapters[index + 1].startTime * 1000)
            } else {
                // Last chapter ends at total duration
                return Int(totalDurationSeconds * 1000)
            }
        }()
        metadataContent += "END=\(endTime)\n"
        metadataContent += "title=\(chapter.title)\n"
        metadataContent += "\n"
    }
    
    return metadataContent
}

// Function to format time for ffmpeg chapter metadata
func formatTimeForFFmpeg(_ time: Double) -> String {
    let hours = Int(time) / 3600
    let minutes = Int(time) % 3600 / 60
    let seconds = Int(time) % 60
    let milliseconds = Int((time - floor(time)) * 1000)
    
    return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
}

// --- Main Script Logic ---

// 1. Check Arguments
guard CommandLine.arguments.count >= 2 else {
    print("Usage: \(CommandLine.arguments[0]) <output_file.m4b> <chapter1.m4b> [chapter2.m4b] ...")
    print("Example: \(CommandLine.arguments[0]) complete_audiobook.m4b 01_Opening_Credits.m4b 02_Chapter_1.m4b 03_Chapter_2.m4b")
    exit(1)
}

let outputFilePath = CommandLine.arguments[1]
let outputFileURL = URL(fileURLWithPath: outputFilePath)

// Get input files from command line arguments
let inputFilePaths = Array(CommandLine.arguments[2...])
let inputFileURLs = inputFilePaths.map { URL(fileURLWithPath: $0) }

// Validate input files exist
print("Validating input files...")
for (index, fileURL) in inputFileURLs.enumerated() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        print("Error: Input file not found: '\(fileURL.path)'")
        exit(1)
    }
    print("  [\(index + 1)/\(inputFileURLs.count)] ✓ \(fileURL.lastPathComponent)")
}

// 2. Find Executables
print("\nResolving dependencies...")
guard let ffmpegURL = findExecutable(named: "ffmpeg") else {
    exit(1)
}
print("  ffmpeg:  \(ffmpegURL.path())")

guard let ffprobeURL = findExecutable(named: "ffprobe") else {
    exit(1)
}
print("  ffprobe: \(ffprobeURL.path())")

// 3. Calculate chapter start times and create chapter info
print("\nAnalyzing chapter files...")
var chapters: [ChapterInfo] = []
var currentTime: Double = 0.0

for (index, fileURL) in inputFileURLs.enumerated() {
    do {
        let duration = try getAudioDuration(fileURL: fileURL, ffprobeURL: ffprobeURL)
        
        // Extract chapter title from filename (remove .m4b extension and number prefix)
        let filename = fileURL.lastPathComponent
        let nameWithoutExt = filename.replacingOccurrences(of: ".m4b", with: "")
        
        // Remove leading number prefix (e.g., "01_" or "1_")
        let title = nameWithoutExt.replacingOccurrences(of: #"^\d+_"#, with: "", options: .regularExpression)
        
        let chapter = ChapterInfo(title: title, startTime: currentTime)
        chapters.append(chapter)
        
        print("  [\(index + 1)/\(inputFileURLs.count)] ✓ \(filename) (\(String(format: "%.1f", duration))s) -> '\(title)'")
        
        currentTime += duration
    } catch {
        print("  [\(index + 1)/\(inputFileURLs.count)] ✗ \(fileURL.lastPathComponent) - Error: \(error.localizedDescription)")
        exit(1)
    }
}

print("\nTotal duration: \(String(format: "%.1f", currentTime))s (\(String(format: "%.1f", currentTime/60)) minutes)")

// 4. Create temporary files for ffmpeg
print("\nPreparing for concatenation...")
let concatFileURL: URL
let metadataFileURL: URL

do {
    concatFileURL = try createConcatFileList(inputFiles: inputFileURLs)
    metadataFileURL = try createChapterMetadata(chapters: chapters, totalDurationSeconds: currentTime)
    print("  ✓ Created temporary files")
} catch {
    print("Error: Failed to create temporary files: \(error)")
    exit(1)
}

// 5. Concatenate files using ffmpeg concat protocol (fast!)
print("\nConcatenating audio files...")
let ffmpegArgs = [
    "-nostdin",  // Prevent ffmpeg from waiting for stdin input
    "-f", "concat",
    "-safe", "0",
    "-i", concatFileURL.path,
    "-f", "ffmetadata",
    "-i", metadataFileURL.path,
    "-map_metadata", "1",
    "-map_chapters", "1",
    "-c", "copy",  // Copy streams without re-encoding - this is the key for speed!
    "-movflags", "use_metadata_tags",
    "-avoid_negative_ts", "make_zero",
    outputFileURL.path
]

print("  Running ffmpeg...")
print("  Command: \(ffmpegURL.path()) \(ffmpegArgs.joined(separator: " "))")
do {
    let (status, stdout, stderr) = try runProcess(executableURL: ffmpegURL, arguments: ffmpegArgs)
    
    if status != 0 {
        print("Error: ffmpeg failed to concatenate files (Exit Code: \(status)).")
        print("ffmpeg stdout:\n\(stdout)")
        print("ffmpeg stderr:\n\(stderr)")
        exit(1)
    }
    
    print("  ✓ Concatenation completed successfully")
} catch {
    print("Error: Failed to run ffmpeg: \(error)")
    exit(1)
}

// Chapters and metadata were mapped in the concat pass; validate downstream if needed.

// 6. Clean up temporary files
do {
    try FileManager.default.removeItem(at: concatFileURL)
    try FileManager.default.removeItem(at: metadataFileURL)
    print("  ✓ Cleaned up temporary files")
} catch {
    print("Warning: Could not clean up temporary files: \(error)")
}

print("\n✓ Audiobook created successfully: '\(outputFilePath)'")
print("  Chapters: \(chapters.count)")
print("  Duration: \(String(format: "%.1f", currentTime))s (\(String(format: "%.1f", currentTime/60)) minutes)")

exit(0)
