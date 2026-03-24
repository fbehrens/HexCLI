# Fish completions for hex-cli

# Disable file completions by default (re-enable for audio file argument)
complete -c hex-cli -f

# Options
complete -c hex-cli -s m -l model    -d "Model for transcription" -x -a "(hex-cli --list-models 2>/dev/null | string match -r '^\s+-\s+\S+' | string replace -r '^\s+-\s+(\S+).*' '\$1')"
complete -c hex-cli -s l -l language -d "Language code (en, de, es, ...)" -x -a "en de es fr it pt nl pl ru zh ja ko"
complete -c hex-cli -s p -l progress -d "Show progress on stderr"
complete -c hex-cli -s j -l json     -d "JSON output with word timestamps"
complete -c hex-cli -s d -l diarize  -d "Run speaker diarization"
complete -c hex-cli      -l list-models -d "List available models"
complete -c hex-cli      -l version  -d "Print version"
complete -c hex-cli -s h -l help     -d "Show help"

# Audio file argument — allow file completions for common audio formats
complete -c hex-cli -a "(__fish_complete_suffix .wav .mp3 .m4a .flac .ogg .aac .wma .opus .aiff .caf)"
