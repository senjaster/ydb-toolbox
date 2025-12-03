#!/bin/sh

set -e
set +u

# Configuration
NODES_FILE=ydb-ca-nodes.txt
KEY_BITS=4096
DN_BASE=""
CLUSTER_NAME=""

# Parse command line arguments
usage() {
    echo "Usage: $0 -d DN_BASE [-c CLUSTER_NAME] [-f NODES_FILE] [-b KEY_BITS]"
    echo "  -d  Base Distinguished Name (required)"
    echo "      Format: comma-separated DN components (e.g., 'C=RU,ST=Moscow,L=Moscow,O=MyOrg,OU=IT')"
    echo "      CN will be automatically appended for each node"
    echo "  -c  Cluster name (will be appended to DNS names, optional)"
    echo "  -f  Nodes file (default: ydb-ca-nodes.txt)"
    echo "  -b  Key bits (default: 4096)"
    echo ""
    echo "Examples:"
    echo "  $0 -d 'O=MyCompany,OU=IT Department'"
    echo "  $0 -d 'C=RU,ST=Moscow,O=MyCompany,OU=Database Team,OU=IT'"
    echo "  $0 -d 'C=US,ST=California,L=San Francisco,O=Example Inc,OU=Engineering'"
    exit 1
}

while getopts "d:c:f:b:h" opt; do
    case $opt in
        d) DN_BASE="$OPTARG" ;;
        c) CLUSTER_NAME="$OPTARG" ;;
        f) NODES_FILE="$OPTARG" ;;
        b) KEY_BITS="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Validate required parameters
if [ -z "$DN_BASE" ]; then
    echo "Error: Base Distinguished Name (-d) is required"
    usage
fi

# Create directory structure
[ -d nodes ] || mkdir nodes
[ -d csr ] || mkdir csr

# Check if nodes file exists
if [ ! -f ${NODES_FILE} ]; then
    echo "** Missing file ${NODES_FILE} - EXIT"
    exit 1
fi

# Function to parse DN components and write them to config file
parse_and_write_dn() {
    local cfile="$1"
    local node_cn="$2"
    local dn_string="$3"
    
    # Parse DN_BASE and write components directly
    # OpenSSL supports both short (C, ST, L, O, OU, CN) and long forms
    # We'll use the format as provided by the user
    local ou_count=0
    
    echo "$dn_string" | tr ',' '\n' | while IFS='=' read -r key value; do
        # Trim whitespace
        key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        if [ ! -z "$key" ] && [ ! -z "$value" ]; then
            # Handle multiple OU fields with numeric suffixes
            if [ "$key" = "OU" ] || [ "$key" = "organizationalUnitName" ]; then
                if [ "$ou_count" -eq 0 ]; then
                    echo "$key = $value" >> ${cfile}
                else
                    echo "${key}_${ou_count} = $value" >> ${cfile}
                fi
                ou_count=$((ou_count + 1))
            else
                echo "$key = $value" >> ${cfile}
            fi
        fi
    done
    
    # Add CN (Common Name) at the end
    echo "CN = ${node_cn}" >> ${cfile}
}

# Function to create node configuration file
make_node_conf() {
    local safe_node="$1"
    local node_fqdn="$2"
    local node_cn="$3"
    local alt_names="$4"
    
    mkdir -p nodes/"$safe_node"
    local cfile=nodes/"$safe_node"/options.cnf
    
    if [ ! -f ${cfile} ]; then
        echo "** Creating node configuration file for $node_fqdn (CN: $node_cn)..."
        
        cat > ${cfile} <<EOF
# OpenSSL node configuration file
[ req ]
prompt=no
distinguished_name = distinguished_name
req_extensions = extensions

[ distinguished_name ]
EOF
        
        # Parse and write DN components from DN_BASE, then add CN
        parse_and_write_dn "${cfile}" "${node_cn}" "${DN_BASE}"
        
        cat >> ${cfile} <<EOF

[ extensions ]
subjectAltName = @alt_names
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth

[ alt_names ]
DNS.1=${node_cn}
DNS.2=${node_fqdn}
IP.1=127.0.0.1
EOF
        
        local vn=2
        local ip_count=1
        
        # Add cluster name to DNS if specified
        if [ ! -z "$CLUSTER_NAME" ]; then
            vn=$(echo "$vn + 1" | bc)
            echo "DNS.$vn=${node_fqdn}.${CLUSTER_NAME}" >> ${cfile}
        fi
        
        # Add additional DNS names if provided
        if [ ! -z "$alt_names" ]; then
            for nn in $alt_names; do
                vn=$(echo "$vn + 1" | bc)
                echo "DNS.$vn=$nn" >> ${cfile}
                
                # Also add cluster name variant for each alt name
                if [ ! -z "$CLUSTER_NAME" ]; then
                    vn=$(echo "$vn + 1" | bc)
                    echo "DNS.$vn=${nn}.${CLUSTER_NAME}" >> ${cfile}
                fi
            done
        fi
    fi
}

# Function to generate node private key
make_node_key() {
    local safe_node="$1"
    local node_fqdn="$2"
    
    if [ ! -f nodes/"$safe_node"/node.key ]; then
        mkdir -p nodes/"$safe_node"
        echo "** Generating key for node $node_fqdn..."
        openssl genrsa -out nodes/"$safe_node"/node.key ${KEY_BITS}
    fi
}

# Function to generate CSR
make_node_csr() {
    local safe_node="$1"
    local node_fqdn="$2"
    
    if [ ! -f csr/"${safe_node}.csr" ]; then
        echo "** Generating CSR for node $node_fqdn..."
        openssl req -new -sha256 -config nodes/"$safe_node"/options.cnf \
            -key nodes/"$safe_node"/node.key \
            -out csr/"${safe_node}.csr" -batch
    fi
}

# Process nodes file
echo "** Processing nodes from ${NODES_FILE}..."
echo "** Base DN: ${DN_BASE}"
if [ ! -z "$CLUSTER_NAME" ]; then
    echo "** Cluster Name: ${CLUSTER_NAME}"
fi
echo ""

# Read nodes file and process each node
(cat ${NODES_FILE}; echo "") | while read node node2; do
    if [ ! -z "$node" ]; then
        # Extract the first part of the FQDN as CN (e.g., "node1" from "node1.example.com")
        node_cn=$(echo "$node" | cut -d'.' -f1)
        
        # Create safe filename (replace special characters)
        safe_node=$(echo "$node" | tr '*$/' '___')
        
        # Generate configuration, key, and CSR
        make_node_conf "$safe_node" "$node" "$node_cn" "$node2"
        make_node_key "$safe_node" "$node"
        make_node_csr "$safe_node" "$node"
    fi
done

echo ""
echo "** All done!"
echo "** Node keys are in: nodes/<node>/node.key"
echo "** CSR files are in: csr/<node>.csr"
echo ""
echo "** Next steps:"
echo "   1. Submit CSR files from csr/ to your Certificate Authority"
echo "   2. Receive signed certificates from CA"
echo "   3. Place certificates in nodes/<node>/node.crt"