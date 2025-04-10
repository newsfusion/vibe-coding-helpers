#!/bin/bash

# --- Configuration ---
# Define colors for output (requires terminal support)
COLOR_RESET="\033[0m"
COLOR_INFO="\033[0;34m"    # Blue
COLOR_SUCCESS="\033[0;32m" # Green
COLOR_WARNING="\033[0;33m" # Yellow
COLOR_ERROR="\033[0;31m"   # Red
COLOR_FILE="\033[0;36m"    # Cyan

# --- Helper Functions ---
log_info() {
  echo -e "${COLOR_INFO}[INFO]${COLOR_RESET} $1"
}

log_success() {
  echo -e "${COLOR_SUCCESS}[SUCCESS]${COLOR_RESET} $1"
}

log_warning() {
  echo -e "${COLOR_WARNING}[WARN]${COLOR_RESET} $1"
}

log_error() {
  echo -e "${COLOR_ERROR}[ERROR]${COLOR_RESET} $1" >&2
}

# --- Argument Parsing and Validation ---
SOURCE_DIR="$1"
OUTPUT_FILE="$2"

if [ -z "$SOURCE_DIR" ] || [ -z "$OUTPUT_FILE" ]; then
  log_error "Usage: $0 /path/to/source /path/to/output.txt"
  exit 1
fi

# Normalize source directory path (remove trailing slash)
SOURCE_DIR="${SOURCE_DIR%/}"

if [ ! -d "$SOURCE_DIR" ]; then
  log_error "Source directory '$SOURCE_DIR' not found or is not a directory."
  exit 1
fi

# Check if output directory is writable
OUTPUT_DIR=$(dirname "$OUTPUT_FILE")
if [ ! -d "$OUTPUT_DIR" ]; then
    log_info "Output directory '$OUTPUT_DIR' does not exist. Creating it..."
    mkdir -p "$OUTPUT_DIR"
    if [ $? -ne 0 ]; then
        log_error "Failed to create output directory '$OUTPUT_DIR'."
        exit 1
    fi
fi
if [ ! -w "$OUTPUT_DIR" ]; then
    log_error "Output directory '$OUTPUT_DIR' is not writable."
    exit 1
fi

# --- Initialization ---
log_info "Starting file merge process."
log_info "Source directory: ${COLOR_FILE}$SOURCE_DIR${COLOR_RESET}"
log_info "Output file: ${COLOR_FILE}$OUTPUT_FILE${COLOR_RESET}"

# Clear or create the output file
log_info "Initializing output file: ${COLOR_FILE}$OUTPUT_FILE${COLOR_RESET}"
> "$OUTPUT_FILE"
if [ $? -ne 0 ]; then
    log_error "Failed to initialize output file '$OUTPUT_FILE'. Check permissions."
    exit 1
fi

# --- File Processing ---
COUNT=0
PROCESSED_COUNT=0

# Check if git is available and the source is inside a git repository
USE_GIT_LS=0
GIT_TOP_LEVEL=""
if command -v git &>/dev/null && git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
    USE_GIT_LS=1
    # Find the top-level directory of the Git repository containing SOURCE_DIR
    GIT_TOP_LEVEL=$(git -C "$SOURCE_DIR" rev-parse --show-toplevel)
    log_info "Git repository detected at '$GIT_TOP_LEVEL'. Using 'git ls-files' for file discovery (respects .gitignore)."
else
    log_warning "Git not found or '$SOURCE_DIR' is not in a Git repository. Using 'find'. .gitignore files will NOT be processed."
fi

# Prepare the command to list files based on whether Git is used
if [ "$USE_GIT_LS" -eq 1 ]; then
    # Use git ls-files: lists tracked and untracked files, respects .gitignore
    # We run it from the Git top level to get paths relative to the repo root
    # Then filter to include only files within the SOURCE_DIR
    # Using NUL delimiters (-z) for safety with special filenames
    FILE_LIST_CMD="git -C \"$GIT_TOP_LEVEL\" ls-files -c -o --exclude-standard --full-name -z -- \"$SOURCE_DIR\""
else
    # Use find: basic filtering, doesn't respect .gitignore
    # Using -print0 for safety with special filenames
    FILE_LIST_CMD="find \"$SOURCE_DIR\" -type f -print0"
fi

log_info "Scanning for files..."

# Process the files found by the chosen command
# Use process substitution and NUL delimiters for robustness
while IFS= read -r -d $'\0' FILE_PATH; do
    # If using git ls-files, the path is relative to GIT_TOP_LEVEL, make it absolute
    if [ "$USE_GIT_LS" -eq 1 ]; then
       ABSOLUTE_FILE_PATH="$GIT_TOP_LEVEL/$FILE_PATH"
    else
       ABSOLUTE_FILE_PATH="$FILE_PATH"
    fi

    # Skip if it's the output file itself (can happen if output is within source)
    if [ "$(realpath "$ABSOLUTE_FILE_PATH")" == "$(realpath "$OUTPUT_FILE")" ]; then
        log_warning "Skipping output file itself: ${COLOR_FILE}$ABSOLUTE_FILE_PATH${COLOR_RESET}"
        continue
    fi

    # Skip common binary file extensions quickly (optional optimization)
    # This is faster than running 'file' on everything, but less accurate
    if [[ "$ABSOLUTE_FILE_PATH" =~ \.(png|jpg|jpeg|gif|bmp|webp|svg|ttf|woff|woff2|tiff|ico|pdf|doc|docx|xls|xlsx|ppt|pptx|zip|gz|tar|tgz|bz2|rar|7z|exe|dll|so|dylib|o|a|class|jar|war|ear|mp3|mp4|avi|mov|wmv|flv|mkv|sqlite|db)$ ]]; then
        log_info "Skipping file (by extension): ${COLOR_FILE}$ABSOLUTE_FILE_PATH${COLOR_RESET}"
        continue
    fi

    # Check if it's a text file using 'file' command (more reliable)
    if file --mime-type "$ABSOLUTE_FILE_PATH" | grep -q 'charset=binary'; then
        log_info "Skipping file (detected by 'file'): ${COLOR_FILE}$ABSOLUTE_FILE_PATH${COLOR_RESET}"
        continue
    fi

    # Calculate relative path for display header
    # Use realpath to handle potential symlinks and get canonical paths before stripping prefix
    DISPLAY_PATH=$(realpath --relative-to="$SOURCE_DIR" "$ABSOLUTE_FILE_PATH")

    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
    log_info "Processing (${PROCESSED_COUNT}): ${COLOR_FILE}$DISPLAY_PATH${COLOR_RESET}"

    # Append file header and content to output file
    echo "### File ${PROCESSED_COUNT}: ${DISPLAY_PATH}" >> "$OUTPUT_FILE"
    cat "$ABSOLUTE_FILE_PATH" >> "$OUTPUT_FILE"
    # Add a newline separator between files for readability
    echo -e "\n" >> "$OUTPUT_FILE"

    # Error check after cat and echo
    if [ $? -ne 0 ]; then
       log_error "Failed to append content from '${ABSOLUTE_FILE_PATH}' to '${OUTPUT_FILE}'. Disk full or permission issue?"
       # Decide whether to exit or continue
       # exit 1 # Exit immediately
       log_warning "Continuing processing despite previous error." # Continue
    fi

done < <(eval "$FILE_LIST_CMD") # Process substitution with eval to handle quoted paths in command

# --- Final Summary ---
if [ "$PROCESSED_COUNT" -eq 0 ]; then
    log_warning "No text files were found or processed in '$SOURCE_DIR'."
else
    log_success "Merged $PROCESSED_COUNT text files into ${COLOR_FILE}$OUTPUT_FILE${COLOR_RESET}"
fi

exit 0
