# Chapter Break

## Description

This Swift script splits an M4B audiobook file into separate M4B files, one for each chapter. It uses `ffprobe` to extract chapter metadata in JSON format and `ffmpeg` to create chapter files without re-encoding the audio.

## Dependencies

Before running the script, you need the following installed and available in your PATH:

1.  **Swift Command Line Tools:** Usually included with Xcode or installable separately.
2.  **ffmpeg:**
3.  **ffprobe:** Included with `ffmpeg`

### Installation (macOS using Homebrew)

If you're on macOS and use [Homebrew](https://brew.sh/), you can install `ffmpeg` (which includes `ffprobe`):

```bash
brew install ffmpeg
```

## Usage

1.  **Make the script executable:**
    ```bash
    chmod +x chapter-break.swift
    ```

2.  **Run the script:**
    Provide the path to your input M4B file as the only argument.
    ```bash
    ./chapter-break.swift /path/to/your/audiobook.m4b
    ```

## Output

The script will create an `output` directory in the same location where you run the script. Inside this directory, you will find the individual chapter files, named using a two-digit chapter number prefix and a sanitized version of the chapter title (e.g., `01_Introduction.m4b`, `02_The_First_Step.m4b`, etc.).

## Notes

*   The script is primarily for macOS but might work on Linux if Swift and ffmpeg are installed.
*   Filename sanitization removes common problematic characters (`/:"<>|?*&%$!@^`~`, smart quotes `""''`, control characters, null) and replaces them with underscores.
*   If chapter titles are missing in the metadata, default names like `Chapter_01`, `Chapter_02` will be used.
*   The script copies the audio codec (`-c copy`) and global metadata (`-map_metadata 0`) without re-encoding, making the process fast and lossless. 
