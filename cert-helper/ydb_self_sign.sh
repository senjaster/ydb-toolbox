#!/bin/sh

set -e
set +u

# Configuration
KEY_BITS=4096
CA_DAYS=3650
INTERMEDIATE_DAYS=1825
CERT_DAYS=825

# Parse command line arguments
usage() {
    echo "Usage: $0 [-o ORGANIZATION] [-d CERT_DAYS] [-i]"
    echo "  -o  Organization name for CA (default: YDB)"
    echo "  -d  Certificate validity days (default: 825)"
    echo "  -i  Generate intermediate CA and use it for signing (creates certificate chain)"
    echo ""
    echo "Examples:"
    echo "  $0                    # Direct signing with root CA"
    echo "  $0 -i                 # Create intermediate CA and sign with it"
    echo "  $0 -i -o MyOrg        # Use custom organization with intermediate CA"
    exit 1
}

ORGANIZATION="YDB"
USE_INTERMEDIATE=0

while getopts "o:d:ih" opt; do
    case $opt in
        o) ORGANIZATION="$OPTARG" ;;
        d) CERT_DAYS="$OPTARG" ;;
        i) USE_INTERMEDIATE=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Create directory structure
[ -d CA ] || mkdir CA
[ -d CA/secure ] || mkdir CA/secure
[ -d CA/newcerts ] || mkdir CA/newcerts
[ -d CA/intermediate ] || mkdir CA/intermediate
[ -d CA/intermediate/secure ] || mkdir CA/intermediate/secure
[ -d CA/intermediate/newcerts ] || mkdir CA/intermediate/newcerts
[ -d certs ] || mkdir certs

# Check if CSR directory exists
if [ ! -d csr ]; then
    echo "** Error: csr/ directory not found"
    echo "** Please run ydb-csr-generate.sh first to generate CSR files"
    exit 1
fi

# Generate CA configuration if it doesn't exist
if [ ! -f CA/ca.cnf ]; then
    echo "** Generating CA configuration file"
    cat >CA/ca.cnf <<EOF
[ ca ]
default_ca = CA_default

[ CA_default ]
default_days = ${CERT_DAYS}
database = CA/index.txt
serial = CA/serial.txt
new_certs_dir = CA/newcerts
default_md = sha256
copy_extensions = copy
unique_subject = no

[ req ]
prompt=no
distinguished_name = distinguished_name
x509_extensions = extensions

[ distinguished_name ]
organizationName = ${ORGANIZATION}
commonName = ${ORGANIZATION} CA

[ extensions ]
keyUsage = critical,digitalSignature,nonRepudiation,keyEncipherment,keyCertSign
basicConstraints = critical,CA:true,pathlen:1

[ intermediate_extensions ]
keyUsage = critical,digitalSignature,nonRepudiation,keyEncipherment,keyCertSign
basicConstraints = critical,CA:true,pathlen:0
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer

[ signing_policy ]
organizationName = supplied
commonName = optional
EOF
fi

# Generate CA key if it doesn't exist
if [ ! -f CA/secure/ca.key ]; then
    echo "** Generating CA private key"
    openssl genrsa -out CA/secure/ca.key ${KEY_BITS}
fi

# Generate CA certificate if it doesn't exist
if [ ! -f CA/ca.crt ]; then
    echo "** Generating self-signed CA certificate"
    openssl req -new -x509 -config CA/ca.cnf -key CA/secure/ca.key -out CA/ca.crt -days ${CA_DAYS} -batch
fi

# Initialize CA database files
[ -f CA/index.txt ] || touch CA/index.txt
[ -f CA/serial.txt ] || (echo 01 >CA/serial.txt)

# Handle intermediate CA if requested
SIGNING_KEY="CA/secure/ca.key"
SIGNING_CERT="CA/ca.crt"
CA_CHAIN_FILE="CA/ca.crt"

if [ $USE_INTERMEDIATE -eq 1 ]; then
    echo ""
    echo "** Setting up intermediate CA..."
    
    # Generate intermediate CA configuration if it doesn't exist
    if [ ! -f CA/intermediate/intermediate.cnf ]; then
        echo "** Generating intermediate CA configuration file"
        cat >CA/intermediate/intermediate.cnf <<EOF
[ ca ]
default_ca = CA_default

[ CA_default ]
default_days = ${CERT_DAYS}
database = CA/intermediate/index.txt
serial = CA/intermediate/serial.txt
new_certs_dir = CA/intermediate/newcerts
default_md = sha256
copy_extensions = copy
unique_subject = no

[ req ]
prompt=no
distinguished_name = distinguished_name
x509_extensions = extensions

[ distinguished_name ]
organizationName = ${ORGANIZATION}
commonName = ${ORGANIZATION} Intermediate CA

[ extensions ]
keyUsage = critical,digitalSignature,nonRepudiation,keyEncipherment,keyCertSign
basicConstraints = critical,CA:true,pathlen:0
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer

[ signing_policy ]
organizationName = supplied
commonName = optional
EOF
    fi
    
    # Generate intermediate CA key if it doesn't exist
    if [ ! -f CA/intermediate/secure/intermediate.key ]; then
        echo "** Generating intermediate CA private key"
        openssl genrsa -out CA/intermediate/secure/intermediate.key ${KEY_BITS}
    fi
    
    # Generate intermediate CA CSR if it doesn't exist
    if [ ! -f CA/intermediate/intermediate.csr ]; then
        echo "** Generating intermediate CA certificate signing request"
        openssl req -new -config CA/intermediate/intermediate.cnf \
            -key CA/intermediate/secure/intermediate.key \
            -out CA/intermediate/intermediate.csr -batch
    fi
    
    # Sign intermediate CA certificate with root CA if it doesn't exist
    if [ ! -f CA/intermediate/intermediate.crt ]; then
        echo "** Signing intermediate CA certificate with root CA"
        openssl ca -config CA/ca.cnf \
            -keyfile CA/secure/ca.key \
            -cert CA/ca.crt \
            -policy signing_policy \
            -extensions intermediate_extensions \
            -out CA/intermediate/intermediate.crt \
            -in CA/intermediate/intermediate.csr \
            -days ${INTERMEDIATE_DAYS} \
            -batch
    fi
    
    # Create certificate chain file (intermediate + root)
    if [ ! -f CA/intermediate/ca-chain.crt ]; then
        echo "** Creating certificate chain file"
        cat CA/intermediate/intermediate.crt CA/ca.crt > CA/intermediate/ca-chain.crt
    fi
    
    # Initialize intermediate CA database files
    [ -f CA/intermediate/index.txt ] || touch CA/intermediate/index.txt
    [ -f CA/intermediate/serial.txt ] || (echo 01 >CA/intermediate/serial.txt)
    
    # Use intermediate CA for signing
    SIGNING_KEY="CA/intermediate/secure/intermediate.key"
    SIGNING_CERT="CA/intermediate/intermediate.crt"
    CA_CHAIN_FILE="CA/intermediate/ca-chain.crt"
    
    echo "** Intermediate CA setup complete"
fi

# Create timestamped output directory
DEST_NAME=$(date "+%Y-%m-%d_%H-%M-%S")
mkdir -p certs/${DEST_NAME}

# Copy CA certificate (or chain) to output directory
cp "$CA_CHAIN_FILE" certs/${DEST_NAME}/ca.crt

echo ""
echo "** Processing CSR files from csr/ directory..."
echo "** CA Organization: ${ORGANIZATION}"
if [ $USE_INTERMEDIATE -eq 1 ]; then
    echo "** Using intermediate CA for signing"
    echo "** Certificate chain: Root CA → Intermediate CA → Node certificates"
else
    echo "** Using root CA for direct signing"
fi
echo "** Certificate validity: ${CERT_DAYS} days"
echo ""

# Process all CSR files
csr_count=0
for csr_file in csr/*.csr; do
    if [ -f "$csr_file" ]; then
        # Extract node name from CSR filename
        node_name=$(basename "$csr_file" .csr)
        
        echo "** Signing certificate for: $node_name"
        
        # Sign the CSR with appropriate CA
        if [ $USE_INTERMEDIATE -eq 1 ]; then
            openssl ca -config CA/intermediate/intermediate.cnf \
                -keyfile "$SIGNING_KEY" \
                -cert "$SIGNING_CERT" \
                -policy signing_policy \
                -out certs/${DEST_NAME}/${node_name}.crt \
                -in "$csr_file" \
                -batch
        else
            openssl ca -config CA/ca.cnf \
                -keyfile "$SIGNING_KEY" \
                -cert "$SIGNING_CERT" \
                -policy signing_policy \
                -out certs/${DEST_NAME}/${node_name}.crt \
                -in "$csr_file" \
                -batch
        fi
        
        csr_count=$((csr_count + 1))
    fi
done

if [ $csr_count -eq 0 ]; then
    echo "** Warning: No CSR files found in csr/ directory"
    echo "** Please run ydb-csr-generate.sh first"
    exit 1
fi

echo ""
echo "** All done!"
echo "** Signed $csr_count certificate(s)"
if [ $USE_INTERMEDIATE -eq 1 ]; then
    echo "** CA certificate chain: certs/${DEST_NAME}/ca.crt (contains intermediate + root)"
    echo "** Root CA: CA/ca.crt"
    echo "** Intermediate CA: CA/intermediate/intermediate.crt"
else
    echo "** CA certificate: certs/${DEST_NAME}/ca.crt"
fi
echo "** Node certificates: certs/${DEST_NAME}/<node>.crt"
echo ""
echo "** Next steps:"
if [ $USE_INTERMEDIATE -eq 1 ]; then
    echo "   1. Distribute ca.crt (chain) to all nodes for trust"
else
    echo "   1. Distribute ca.crt to all nodes for trust"
fi
echo "   2. Distribute <node>.crt to corresponding nodes"
echo "   3. Use with node keys from nodes/<node>/node.key"