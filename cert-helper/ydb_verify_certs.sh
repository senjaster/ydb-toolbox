#!/bin/sh

set -e
set +u

# Certificate sanity check.
#
# This script verifies that for each node:
#     1) private key, csr and certificate match each other
#     2) certificate is really signed by ca.crt
#     3) web.pem contains valid sequence of key and certificates 
#     4) node.crt can be used for sslclient and sslserver purposes

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
NODES_FILE="ydb-ca-nodes.txt"
EXPIRY_WARNING_DAYS=30

# Parse command line arguments
usage() {
    echo "Usage: $0 [-n NODE_NAME] [-f NODES_FILE] [-w DAYS] [-v]"
    echo "  -n  Verify specific node only (optional)"
    echo "  -f  Nodes file to check against (default: ydb-ca-nodes.txt)"
    echo "  -w  Days before expiry to warn (default: 30)"
    echo "  -v  Verbose mode (show detailed certificate info)"
    echo ""
    echo "Example:"
    echo "  $0                    # Verify all nodes"
    echo "  $0 -n static-node-1.ydb-cluster.com"
    echo "  $0 -v                 # Verbose mode for all nodes"
    echo "  $0 -w 60              # Warn if expiring within 60 days"
    exit 1
}

NODE_NAME=""
VERBOSE=0

while getopts "n:f:w:vh" opt; do
    case $opt in
        n) NODE_NAME="$OPTARG" ;;
        f) NODES_FILE="$OPTARG" ;;
        w) EXPIRY_WARNING_DAYS="$OPTARG" ;;
        v) VERBOSE=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Check if nodes directory exists
if [ ! -d nodes ]; then
    echo "${RED}** Error: nodes/ directory not found${NC}"
    echo "** Please run ydb_generate_csr.sh first"
    exit 1
fi

# Check if CA certificate exists
if [ ! -f nodes/ca.crt ]; then
    echo "${RED}** Error: CA certificate not found at nodes/ca.crt${NC}"
    echo "** Please run ydb_arrange_certs.sh first"
    exit 1
fi

# Function to print success message
print_success() {
    echo "${GREEN}✓ $1${NC}"
}

# Function to print error message
print_error() {
    echo "${RED}✗ $1${NC}"
}

# Function to print warning message
print_warning() {
    echo "${YELLOW}⚠ $1${NC}"
}

# Function to check certificate expiration (handles certificate chains)
check_expiration() {
    local cert_file="$1"
    local cert_name="$2"
    local cert_index="${3:-1}"  # Default to first certificate
    
    # Extract specific certificate from chain
    local temp_file=$(mktemp)
    awk -v idx="$cert_index" '
        /BEGIN CERTIFICATE/ { count++; capture=(count==idx) }
        capture { print }
        /END CERTIFICATE/ && capture { exit }
    ' "$cert_file" > "$temp_file"
    
    if [ ! -s "$temp_file" ]; then
        rm -f "$temp_file"
        if [ "$cert_index" -eq 1 ]; then
            print_error "Cannot read certificate from $cert_name"
            return 1
        fi
        return 0  # No more certificates in chain
    fi
    
    # Get expiration date
    local not_after=$(openssl x509 -noout -enddate -in "$temp_file" 2>/dev/null | cut -d= -f2)
    local not_before=$(openssl x509 -noout -startdate -in "$temp_file" 2>/dev/null | cut -d= -f2)
    
    if [ -z "$not_after" ]; then
        rm -f "$temp_file"
        print_error "Cannot read expiration date from $cert_name"
        return 1
    fi
    
    # Convert dates to epoch for comparison
    local not_after_epoch=$(date -j -f "%b %d %T %Y %Z" "$not_after" "+%s" 2>/dev/null || date -d "$not_after" "+%s" 2>/dev/null)
    local not_before_epoch=$(date -j -f "%b %d %T %Y %Z" "$not_before" "+%s" 2>/dev/null || date -d "$not_before" "+%s" 2>/dev/null)
    local current_epoch=$(date "+%s")
    
    rm -f "$temp_file"
    
    # Check if certificate is not yet valid
    if [ "$current_epoch" -lt "$not_before_epoch" ]; then
        print_error "$cert_name is not yet valid (valid from: $not_before)"
        return 1
    fi
    
    # Check if certificate is expired
    if [ "$current_epoch" -gt "$not_after_epoch" ]; then
        print_error "$cert_name is EXPIRED (expired on: $not_after)"
        return 1
    fi
    
    # Calculate days until expiration
    local seconds_until_expiry=$((not_after_epoch - current_epoch))
    local days_until_expiry=$((seconds_until_expiry / 86400))
    
    # Warn if expiring soon
    if [ "$days_until_expiry" -le "$EXPIRY_WARNING_DAYS" ]; then
        print_warning "$cert_name expires in $days_until_expiry days (on: $not_after)"
    else
        print_success "$cert_name is valid (expires in $days_until_expiry days)"
    fi
    
    return 0
}

# Function to check all certificates in a chain file
check_chain_expiration() {
    local cert_file="$1"
    local file_name="$2"
    
    # Count certificates in the file
    local cert_count=$(grep -c "BEGIN CERTIFICATE" "$cert_file" 2>/dev/null || echo "0")
    
    if [ "$cert_count" -eq 0 ]; then
        print_error "No certificates found in $file_name"
        return 1
    fi
    
    local errors=0
    
    if [ "$cert_count" -eq 1 ]; then
        # Single certificate
        if ! check_expiration "$cert_file" "$file_name" 1; then
            errors=$((errors + 1))
        fi
    else
        # Certificate chain
        print_success "$file_name contains $cert_count certificate(s) in chain"
        for i in $(seq 1 $cert_count); do
            local cert_desc="$file_name [cert $i/$cert_count]"
            if ! check_expiration "$cert_file" "$cert_desc" "$i"; then
                errors=$((errors + 1))
            fi
        done
    fi
    
    return $errors
}

# Function to extract and verify certificate chain from PEM file
verify_cert_chain() {
    local pem_file="$1"
    local node_name="$2"
    
    # Extract all certificates from the PEM file
    local temp_dir=$(mktemp -d)
    local cert_index=0
    
    # Split certificates
    awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' "$pem_file" | \
    awk -v dir="$temp_dir" '
        /BEGIN CERTIFICATE/ { cert_index++; file=dir"/cert"cert_index".pem" }
        { print > file }
    '
    
    local cert_count=$(ls -1 "$temp_dir"/cert*.pem 2>/dev/null | wc -l | tr -d ' ')
    
    if [ "$cert_count" -eq 0 ]; then
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Verify each certificate in the chain
    local chain_valid=0
    for i in $(seq 1 $cert_count); do
        local cert_file="$temp_dir/cert${i}.pem"
        if [ -f "$cert_file" ]; then
            # Check if it's the node certificate or CA certificate
            local subject=$(openssl x509 -noout -subject -in "$cert_file" 2>/dev/null)
            local issuer=$(openssl x509 -noout -issuer -in "$cert_file" 2>/dev/null)
            
            if [ "$i" -eq 1 ]; then
                # First cert should be the node certificate
                if openssl verify -CAfile nodes/ca.crt "$cert_file" >/dev/null 2>&1; then
                    chain_valid=1
                fi
            fi
        fi
    done
    
    rm -rf "$temp_dir"
    return $((1 - chain_valid))
}

# Function to validate PEM format
validate_pem_format() {
    local pem_file="$1"
    local file_name="$2"
    
    # Check for proper PEM markers
    if ! grep -q "BEGIN.*PRIVATE KEY" "$pem_file" && ! grep -q "BEGIN CERTIFICATE" "$pem_file"; then
        print_error "$file_name does not contain valid PEM data"
        return 1
    fi
    
    # Check for corrupted PEM blocks (mismatched BEGIN/END)
    local begin_count=$(grep -c "^-----BEGIN" "$pem_file" 2>/dev/null || echo "0")
    local end_count=$(grep -c "^-----END" "$pem_file" 2>/dev/null || echo "0")
    
    if [ "$begin_count" -ne "$end_count" ]; then
        print_error "$file_name has mismatched BEGIN/END markers ($begin_count BEGIN, $end_count END)"
        return 1
    fi
    
    # Try to parse each certificate to ensure it's not corrupted
    local temp_file=$(mktemp)
    awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' "$pem_file" > "$temp_file"
    
    if [ -s "$temp_file" ]; then
        if ! openssl x509 -noout -in "$temp_file" 2>/dev/null; then
            rm -f "$temp_file"
            print_error "$file_name contains corrupted certificate data"
            return 1
        fi
    fi
    
    rm -f "$temp_file"
    return 0
}

# Function to check for duplicate certificates in PEM
check_duplicate_certs() {
    local pem_file="$1"
    
    # Extract certificate fingerprints
    local temp_dir=$(mktemp -d)
    awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' "$pem_file" | \
    awk -v dir="$temp_dir" '
        /BEGIN CERTIFICATE/ { cert_index++; file=dir"/cert"cert_index".pem" }
        { print > file }
    '
    
    local fingerprints=""
    for cert_file in "$temp_dir"/cert*.pem; do
        if [ -f "$cert_file" ]; then
            local fp=$(openssl x509 -noout -fingerprint -sha256 -in "$cert_file" 2>/dev/null | cut -d= -f2)
            if echo "$fingerprints" | grep -q "$fp"; then
                rm -rf "$temp_dir"
                return 1
            fi
            fingerprints="$fingerprints $fp"
        fi
    done
    
    rm -rf "$temp_dir"
    return 0
}

# Function to verify a single node
verify_node() {
    local node_dir="$1"
    local node_name=$(basename "$node_dir")
    local errors=0
    
    echo ""
    echo "=========================================="
    echo "Verifying node: $node_name"
    echo "=========================================="
    
    # Check if required files exist
    if [ ! -f "$node_dir/node.key" ]; then
        print_error "Private key not found: $node_dir/node.key"
        return 1
    fi
    
    if [ ! -f "$node_dir/node.crt" ]; then
        print_error "Certificate not found: $node_dir/node.crt"
        return 1
    fi
    
    # Check 1: Verify private key and certificate match
    echo ""
    echo "Check 1: Verifying private key and certificate match..."
    
    key_modulus=$(openssl rsa -noout -modulus -in "$node_dir/node.key" 2>/dev/null | openssl md5)
    cert_modulus=$(openssl x509 -noout -modulus -in "$node_dir/node.crt" 2>/dev/null | openssl md5)
    
    if [ "$key_modulus" = "$cert_modulus" ]; then
        print_success "Private key and certificate match"
    else
        print_error "Private key and certificate DO NOT match"
        errors=$((errors + 1))
    fi
    
    # Check 1b: If CSR exists, verify it matches the key
    if [ -f "csr/${node_name}.csr" ]; then
        echo ""
        echo "Check 1b: Verifying CSR matches private key..."
        
        csr_modulus=$(openssl req -noout -modulus -in "csr/${node_name}.csr" 2>/dev/null | openssl md5)
        
        if [ "$key_modulus" = "$csr_modulus" ]; then
            print_success "CSR and private key match"
        else
            print_error "CSR and private key DO NOT match"
            errors=$((errors + 1))
        fi
    fi
    
    # Check 2: Verify certificate is signed by CA
    echo ""
    echo "Check 2: Verifying certificate is signed by CA..."
    
    if openssl verify -CAfile nodes/ca.crt "$node_dir/node.crt" >/dev/null 2>&1; then
        print_success "Certificate is properly signed by CA"
    else
        print_error "Certificate verification against CA failed"
        errors=$((errors + 1))
    fi
    
    # Check 3: Verify web.pem structure
    echo ""
    echo "Check 3: Verifying web.pem structure..."
    
    if [ ! -f "$node_dir/web.pem" ]; then
        print_error "web.pem not found"
        errors=$((errors + 1))
    else
        # Check if web.pem contains private key
        if grep -q "BEGIN.*PRIVATE KEY" "$node_dir/web.pem"; then
            print_success "web.pem contains private key"
        else
            print_error "web.pem does not contain private key"
            errors=$((errors + 1))
        fi
        
        # Check if web.pem contains certificate
        cert_count=$(grep -c "BEGIN CERTIFICATE" "$node_dir/web.pem" || echo "0")
        if [ "$cert_count" -ge 1 ]; then
            print_success "web.pem contains certificate(s) (found $cert_count)"
        else
            print_error "web.pem does not contain any certificates"
            errors=$((errors + 1))
        fi
        
        # Verify the order: key should come before certificates
        key_line=$(grep -n "BEGIN.*PRIVATE KEY" "$node_dir/web.pem" | head -1 | cut -d: -f1)
        cert_line=$(grep -n "BEGIN CERTIFICATE" "$node_dir/web.pem" | head -1 | cut -d: -f1)
        
        if [ ! -z "$key_line" ] && [ ! -z "$cert_line" ]; then
            if [ "$key_line" -lt "$cert_line" ]; then
                print_success "web.pem has correct order (key before certificates)"
            else
                print_error "web.pem has incorrect order (certificates before key)"
                errors=$((errors + 1))
            fi
        fi
    fi
    
    # Check 4: Verify certificate can be used for SSL client and server
    echo ""
    echo "Check 4: Verifying certificate usage (SSL client/server)..."
    
    # Check Extended Key Usage
    ext_key_usage=$(openssl x509 -noout -ext extendedKeyUsage -in "$node_dir/node.crt" 2>/dev/null || echo "")
    
    if echo "$ext_key_usage" | grep -q "TLS Web Server Authentication"; then
        print_success "Certificate has serverAuth (SSL server) usage"
    else
        print_error "Certificate missing serverAuth (SSL server) usage"
        errors=$((errors + 1))
    fi
    
    if echo "$ext_key_usage" | grep -q "TLS Web Client Authentication"; then
        print_success "Certificate has clientAuth (SSL client) usage"
    else
        print_error "Certificate missing clientAuth (SSL client) usage"
        errors=$((errors + 1))
    fi
    
    # Check Key Usage
    key_usage=$(openssl x509 -noout -ext keyUsage -in "$node_dir/node.crt" 2>/dev/null || echo "")
    
    if echo "$key_usage" | grep -q "Digital Signature"; then
        print_success "Certificate has Digital Signature key usage"
    else
        print_warning "Certificate missing Digital Signature key usage"
    fi
    
    if echo "$key_usage" | grep -q "Key Encipherment"; then
        print_success "Certificate has Key Encipherment key usage"
    else
        print_warning "Certificate missing Key Encipherment key usage"
    fi
    
    # Check 5: Certificate expiration
    echo ""
    echo "Check 5: Verifying certificate expiration..."
    
    if ! check_expiration "$node_dir/node.crt" "Node certificate"; then
        errors=$((errors + 1))
    fi
    
    # Check 6: Certificate chain validation in web.pem
    if [ -f "$node_dir/web.pem" ]; then
        echo ""
        echo "Check 6: Verifying certificate chain in web.pem..."
        
        if verify_cert_chain "$node_dir/web.pem" "$node_name"; then
            print_success "Certificate chain in web.pem is valid"
        else
            print_error "Certificate chain validation failed in web.pem"
            errors=$((errors + 1))
        fi
    fi
    
    # Check 7: Subject Alternative Names validation
    echo ""
    echo "Check 7: Verifying Subject Alternative Names..."
    
    san_output=$(openssl x509 -noout -ext subjectAltName -in "$node_dir/node.crt" 2>/dev/null)
    
    if [ -z "$san_output" ]; then
        print_warning "No Subject Alternative Names found in certificate"
    else
        # Extract DNS names from SAN
        san_dns=$(echo "$san_output" | grep -o "DNS:[^,]*" | cut -d: -f2 | tr -d ' ')
        san_count=$(echo "$san_dns" | wc -l | tr -d ' ')
        
        if [ "$san_count" -gt 0 ]; then
            print_success "Certificate contains $san_count DNS name(s) in SAN"
            
            # Check if node name is in SAN
            if echo "$san_dns" | grep -q "^${node_name}$"; then
                print_success "Node name ($node_name) found in SAN"
            else
                print_warning "Node name ($node_name) not found in SAN"
            fi
        else
            print_warning "No DNS names found in Subject Alternative Names"
        fi
    fi
    
    # Check 8: PEM format validation
    echo ""
    echo "Check 8: Validating PEM format..."
    
    if validate_pem_format "$node_dir/node.crt" "node.crt"; then
        print_success "node.crt has valid PEM format"
    else
        errors=$((errors + 1))
    fi
    
    if [ -f "$node_dir/web.pem" ]; then
        if validate_pem_format "$node_dir/web.pem" "web.pem"; then
            print_success "web.pem has valid PEM format"
        else
            errors=$((errors + 1))
        fi
        
        # Check for duplicate certificates
        if check_duplicate_certs "$node_dir/web.pem"; then
            print_success "web.pem contains no duplicate certificates"
        else
            print_warning "web.pem contains duplicate certificates"
        fi
    fi
    
    # Verbose mode: show certificate details
    if [ $VERBOSE -eq 1 ]; then
        echo ""
        echo "Certificate Details:"
        echo "--------------------"
        openssl x509 -noout -subject -issuer -dates -ext subjectAltName -in "$node_dir/node.crt"
    fi
    
    # Summary for this node
    echo ""
    if [ $errors -eq 0 ]; then
        print_success "All checks passed for $node_name"
        return 0
    else
        print_error "Found $errors error(s) for $node_name"
        return 1
    fi
}

# Main verification logic
echo "=========================================="
echo "YDB Certificate Verification"
echo "=========================================="
echo "CA Certificate: nodes/ca.crt"

# Check CA certificate expiration (may contain chain)
echo ""
echo "Verifying CA certificate(s)..."

# Count certificates in CA file
ca_cert_count=$(grep -c "BEGIN CERTIFICATE" "nodes/ca.crt" 2>/dev/null || echo "0")

if [ "$ca_cert_count" -gt 1 ]; then
    print_success "CA file contains certificate chain ($ca_cert_count certificates)"
fi

if ! check_chain_expiration "nodes/ca.crt" "CA certificate"; then
    echo "${RED}** Warning: CA certificate chain has expiration issues${NC}"
fi

# Check 9: Configuration file consistency
if [ -f "$NODES_FILE" ]; then
    echo ""
    echo "Checking configuration file consistency..."
    echo "Nodes file: $NODES_FILE"
    
    # Read expected nodes from file
    expected_nodes=""
    while read -r node rest; do
        if [ ! -z "$node" ]; then
            safe_node=$(echo "$node" | tr '*$/' '___')
            expected_nodes="$expected_nodes $safe_node"
        fi
    done < "$NODES_FILE"
    
    # Check if all expected nodes have certificates
    missing_nodes=0
    for expected in $expected_nodes; do
        if [ ! -d "nodes/$expected" ] || [ ! -f "nodes/$expected/node.crt" ]; then
            print_warning "Node from $NODES_FILE missing certificate: $expected"
            missing_nodes=$((missing_nodes + 1))
        fi
    done
    
    if [ $missing_nodes -eq 0 ]; then
        print_success "All nodes from $NODES_FILE have certificates"
    fi
    
    # Check for extra nodes not in the file
    extra_nodes=0
    for node_dir in nodes/*/; do
        if [ -d "$node_dir" ]; then
            node_name=$(basename "$node_dir")
            if [ "$node_name" != "*" ] && ! echo "$expected_nodes" | grep -q "$node_name"; then
                print_warning "Certificate exists for node not in $NODES_FILE: $node_name"
                extra_nodes=$((extra_nodes + 1))
            fi
        fi
    done
else
    print_warning "Nodes file not found: $NODES_FILE (skipping consistency check)"
fi

echo ""
echo "=========================================="

total_nodes=0
failed_nodes=0

# If specific node is specified, verify only that node
if [ ! -z "$NODE_NAME" ]; then
    safe_node=$(echo "$NODE_NAME" | tr '*$/' '___')
    
    if [ ! -d "nodes/$safe_node" ]; then
        echo "${RED}** Error: Node directory not found: nodes/$safe_node${NC}"
        exit 1
    fi
    
    total_nodes=1
    if ! verify_node "nodes/$safe_node"; then
        failed_nodes=1
    fi
else
    # Verify all nodes
    for node_dir in nodes/*/; do
        # Skip if not a directory or if it's just the nodes/ directory itself
        if [ ! -d "$node_dir" ] || [ "$node_dir" = "nodes/" ]; then
            continue
        fi
        
        # Skip if directory only contains ca.crt
        node_name=$(basename "$node_dir")
        if [ "$node_name" = "*" ]; then
            continue
        fi
        
        total_nodes=$((total_nodes + 1))
        
        if ! verify_node "$node_dir"; then
            failed_nodes=$((failed_nodes + 1))
        fi
    done
fi

# Final summary
echo ""
echo "=========================================="
echo "Verification Summary"
echo "=========================================="
echo "Total nodes checked: $total_nodes"
echo "Passed: $((total_nodes - failed_nodes))"
echo "Failed: $failed_nodes"
echo ""

if [ $failed_nodes -eq 0 ]; then
    print_success "All certificates are valid!"
    exit 0
else
    print_error "Some certificates have issues. Please review the errors above."
    exit 1
fi
