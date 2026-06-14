-- Transcribe.app droplet.
-- When the user drags audio files onto the app, we open Terminal
-- and run the bundled worker script for each one.

on open theFiles
    set appPath to (POSIX path of (path to me))
    set workerPath to appPath & "Contents/Resources/transcribe.sh"
    repeat with theFile in theFiles
        set filePath to POSIX path of theFile
        tell application "Terminal"
            activate
            do script (quoted form of workerPath) & " " & (quoted form of filePath)
        end tell
    end repeat
end open

on run
    display dialog "Drag an audio file (.m4a, .mp3, .wav, .mp4) onto this app's icon to transcribe it." & return & return & "The transcript is saved next to the audio file with speaker labels." buttons {"OK"} default button "OK"
end run
