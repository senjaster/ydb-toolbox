#!/bin/bash

# YDB Interactive Shell Wrapper
# Provides convenient interactive access to YDB tools without repeating authentication parameters

# set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
print_info() {
    echo -e "${BLUE}[INFO]${NC}    $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC}   $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -e|--endpoint)
                ENDPOINT_ARG="$2"
                shift 2
                ;;
            -d|--database)
                DATABASE_ARG="$2"
                shift 2
                ;;
            --ca-file)
                CA_FILE_ARG="$2"
                shift 2
                ;;
            --user)
                USER_ARG="$2"
                shift 2
                ;;
            --password-file)
                PASSWORD_FILE_ARG="$2"
                shift 2
                ;;
            --no-password)
                NO_PASSWORD_FLAG=true
                shift
                ;;
            -h|--help)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  -e, --endpoint HOST[:PORT]    YDB endpoint (env: YDB_ENDPOINT)"
                echo "  -d, --database PATH           Database path (env: YDB_DATABASE)"
                echo "  --ca-file PATH                CA certificate file (env: YDB_CA_FILE)"
                echo "  --user NAME                   User name (env: YDB_USER)"
                echo "  --password-file PATH          Password file (env: YDB_PASSWORD)"
                echo "  --no-password                 Use anonymous authentication (no password)"
                echo "  -h, --help                    Show this help"
                echo ""
                echo "Environment variables with defaults:"
                echo "  YDB_ENDPOINT  - default: grpcs://\$(hostname):2135"
                echo "  YDB_DATABASE  - default: /Root"
                echo "  YDB_CA_FILE   - default: /opt/ydb/certs/ca.crt"
                echo "  YDB_USER      - default: root"
                echo ""
                echo "Password handling:"
                echo "  - If --password-file is provided, password is read from file"
                echo "  - If YDB_PASSWORD env var is set, it will be used"
                echo "  - If --no-password is provided, anonymous authentication is used"
                echo "  - Otherwise, YDB will prompt for password interactively"
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use -h or --help for usage information"
                exit 1
                ;;
        esac
    done
}

# Set default values for environment variables
set_defaults() {
    # Use command line args if provided, otherwise use env vars, otherwise use defaults
    
    # Endpoint
    if [ -n "$ENDPOINT_ARG" ]; then
        export YDB_ENDPOINT="$ENDPOINT_ARG"
    elif [ -z "$YDB_ENDPOINT" ]; then
        local current_hostname=$(hostname)
        export YDB_ENDPOINT="grpcs://${current_hostname}:2135"
        print_info "Using default YDB_ENDPOINT: $YDB_ENDPOINT"
    fi
    
    # Database
    if [ -n "$DATABASE_ARG" ]; then
        export YDB_DATABASE="$DATABASE_ARG"
    elif [ -z "$YDB_DATABASE" ]; then
        export YDB_DATABASE="/Root"
        print_info "Using default YDB_DATABASE: $YDB_DATABASE"
    fi
    
    # CA File
    if [ -n "$CA_FILE_ARG" ]; then
        export YDB_CA_FILE="$CA_FILE_ARG"
    elif [ -z "$YDB_CA_FILE" ]; then
        export YDB_CA_FILE="/opt/ydb/certs/ca.crt"
        print_info "Using default YDB_CA_FILE: $YDB_CA_FILE"
    fi
    
    # User
    if [ -n "$USER_ARG" ]; then
        export YDB_USER="$USER_ARG"
    elif [ -z "$YDB_USER" ]; then
        export YDB_USER="root"
        print_info "Using default YDB_USER: $YDB_USER"
    fi
    
    # Password file (optional) - read password from file if provided
    if [ -n "$PASSWORD_FILE_ARG" ]; then
        if [ -f "$PASSWORD_FILE_ARG" ]; then
            export YDB_PASSWORD=$(cat "$PASSWORD_FILE_ARG")
        else
            print_error "Password file not found: $PASSWORD_FILE_ARG"
            exit 1
        fi
    fi
    
    # Check if CA file exists
    if [ ! -f "$YDB_CA_FILE" ]; then
        print_warning "CA file not found: $YDB_CA_FILE"
        print_warning "You may need to set YDB_CA_FILE to the correct path"
    fi
}

# Find YDB binary in PATH, script directory, or /opt/ydb/bin
find_ydb_binary() {
    local binary_name="$1"
    
    # Check in PATH
    if command -v "$binary_name" &> /dev/null; then
        command -v "$binary_name"
        return 0
    fi
    
    # Check in script directory
    if [ -x "$SCRIPT_DIR/$binary_name" ]; then
        echo "$SCRIPT_DIR/$binary_name"
        return 0
    fi
    
    # Check in /opt/ydb/bin
    if [ -x "/opt/ydb/bin/$binary_name" ]; then
        echo "/opt/ydb/bin/$binary_name"
        return 0
    fi
    
    return 1
}

# Check if required binaries exist and set paths
check_binaries() {
    local missing_bins=()
    
    # Find ydb binary
    if YDB_BIN=$(find_ydb_binary "ydb"); then
        print_info "Found ydb at: $YDB_BIN"
    else
        missing_bins+=("ydb")
    fi
    
    # Find ydbd binary
    if YDBD_BIN=$(find_ydb_binary "ydbd"); then
        print_info "Found ydbd at: $YDBD_BIN"
    else
        missing_bins+=("ydbd")
    fi
    
    # Find ydb-dstool binary
    if YDB_DSTOOL_BIN=$(find_ydb_binary "ydb-dstool"); then
        print_info "Found ydb-dstool at: $YDB_DSTOOL_BIN"
    else
        missing_bins+=("ydb-dstool")
    fi
    
    # Find ydbops binary (optional)
    if YDBOPS_BIN=$(find_ydb_binary "ydbops"); then
        print_info "Found ydbops at: $YDBOPS_BIN"
    fi
    
    if [ ${#missing_bins[@]} -ne 0 ]; then
        print_error "Required YDB binaries not found: ${missing_bins[*]}"
        print_error "Please ensure YDB tools are installed in PATH, $SCRIPT_DIR, or /opt/ydb/bin"
        exit 1
    fi
}

# Get authentication token
get_token() {
    local token_file="$1"
    
    print_info "Obtaining authentication token for user: $YDB_USER"
    
    # Build command with explicit parameters
    local cmd=("$YDB_BIN" -e "$YDB_ENDPOINT" -d "$YDB_DATABASE" --ca-file "$YDB_CA_FILE" --user "$YDB_USER")
    
    # Determine authentication method
    if [ "$NO_PASSWORD_FLAG" = true ]; then
        # Explicit --no-password flag provided - use anonymous authentication
        print_info "Using anonymous authentication (--no-password)"
        if "${cmd[@]}" --no-password auth get-token --force > "$token_file" 2>&1; then
            print_success "Token obtained successfully"
            return 0
        fi
    elif [ -n "$YDB_PASSWORD" ]; then
        # Password provided via env var or --password-file
        print_info "Using password authentication"
        if YDB_PASSWORD="$YDB_PASSWORD" "${cmd[@]}" auth get-token --force > "$token_file" 2>&1; then
            print_success "Token obtained successfully"
            return 0
        fi
    else
        # No password provided - let YDB prompt for it interactively
        echo -e -n "${BLUE}[INFO]${NC}    "  # Ydb will print it's prompt here
        if "${cmd[@]}" auth get-token --force > "$token_file" ; then
            print_success "Token obtained successfully"
            return 0
        fi
    fi
    
    print_error "Failed to obtain authentication token"
    cat "$token_file" >&2
    return 1
}

# Create aliases file
create_aliases() {
    local token_file="$1"
    local aliases_file="$2"
    
    cat > "$aliases_file" << EOF
# YDB Tools Aliases
# Auto-generated by ydb-shell.sh

# Export YDB environment variables for native support
export YDB_ENDPOINT="$YDB_ENDPOINT"
export YDB_DATABASE="$YDB_DATABASE"
export YDB_CA_FILE="$YDB_CA_FILE"
export YDB_USER="$YDB_USER"
export YDB_TOKEN="$token_file"

# Set LD_LIBRARY_PATH if not already set
if [ -z "\$LD_LIBRARY_PATH" ] && [ -d "/opt/ydb/lib" ]; then
    export LD_LIBRARY_PATH=/opt/ydb/lib
fi

# YDB CLI client - uses environment variables natively
alias ydb='$YDB_BIN -e \$YDB_ENDPOINT -d \$YDB_DATABASE --token-file \$YDB_TOKEN'

# YDB daemon (server) commands
alias ydbd='$YDBD_BIN -s \$YDB_ENDPOINT --ca-file \$YDB_CA_FILE -f \$YDB_TOKEN'

# YDB distributed storage tool
alias ydb-dstool='$YDB_DSTOOL_BIN -e \$YDB_ENDPOINT --ca-file \$YDB_CA_FILE --token-file \$YDB_TOKEN'

# YDB operations tool (if available)
if [ -n "$YDBOPS_BIN" ]; then
    alias ydbops='$YDBOPS_BIN'
fi

# Helper function to show available commands
ydb-help() {
    echo ""
    echo "Available YDB commands:"
    echo "  ydb          - YDB CLI client"
    echo "  ydbd         - YDB daemon commands"
    echo "  ydb-dstool   - Distributed storage tool"
    echo "  ydbops       - Operations tool (if available)"
    echo ""
    echo "Examples:"
    echo "  ydb scheme ls"
    echo "  ydb sql -s 'SELECT version()'"
    echo "  ydbd admin database list"
    echo "  ydb-dstool pdisk list"
    echo ""
    echo "Type 'exit' to leave YDB shell"
    echo ""
}

# Show help on startup
ydb-help
EOF
}

# Main function
main() {
    print_info "Starting YDB Interactive Shell"
    print_info ""
    
    # Parse command line arguments
    parse_args "$@"
    
    # Set default values
    set_defaults
    
    # Check binaries
    check_binaries
    
    # Create temporary files
    local token_file=$(mktemp /tmp/ydb-token.XXXXXX)
    local aliases_file=$(mktemp /tmp/ydb-aliases.XXXXXX)
    
    # Cleanup on exit
    trap "rm -f $token_file $aliases_file" EXIT
    
    # Get authentication token
    if ! get_token "$token_file"; then
        exit 1
    fi
    
    # Create aliases
    create_aliases "$token_file" "$aliases_file"
    
    print_info ""
    print_success "YDB Interactive Shell is ready!"
    print_info "Token file: $token_file"
    print_info ""
    
    # Determine shell
    local shell_cmd="${SHELL:-/bin/bash}"
    
    # Start interactive shell with aliases
    if [[ "$shell_cmd" == *"zsh"* ]]; then
        # For zsh
        ZDOTDIR=/tmp zsh -c "source $aliases_file; exec zsh"
    else
        # For bash
        bash --rcfile "$aliases_file"
    fi
    
    print_info ""
    print_info "Exiting YDB Interactive Shell"
}

# Run main function
main "$@"