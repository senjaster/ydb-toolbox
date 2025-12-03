#!/bin/sh

set -e
set +u

# Parse command line arguments
usage() {
    echo "Usage: $0 [-d CERTS_DIR] [-c CA_CERT] [-k]"
    echo "  -d  Directory with signed certificates (required)"
    echo "  -c  CA certificate file (optional, will be copied if provided)"
    echo "  -k  Copy private keys from certificates directory (for CA-generated certificates)"
    echo ""
    echo "Examples:"
    echo "  # When keys were generated locally (default scenario)"
    echo "  $0 -d certs/2025-11-25_17-02-52 -c certs/2025-11-25_17-02-52/ca.crt"
    echo ""
    echo "  # When CA generated both certificates and keys"
    echo "  $0 -d certs/from-ca -c certs/from-ca/ca.crt -k"
    exit 1
}

CERTS_DIR=""
CA_CERT=""
COPY_KEYS=false

while getopts "d:c:kh" opt; do
    case $opt in
        d) CERTS_DIR="$OPTARG" ;;
        c) CA_CERT="$OPTARG" ;;
        k) COPY_KEYS=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Validate required parameters
if [ -z "$CERTS_DIR" ]; then
    echo "Error: Certificates directory (-d) is required"
    usage
fi

# Check if certificates directory exists
if [ ! -d "$CERTS_DIR" ]; then
    echo "** Error: Certificates directory not found: $CERTS_DIR"
    exit 1
fi

# Check if nodes directory exists (create if copying keys from CA)
if [ ! -d nodes ]; then
    if [ "$COPY_KEYS" = true ]; then
        echo "** Creating nodes/ directory"
        mkdir -p nodes
    else
        echo "** Error: nodes/ directory not found"
        echo "** Please run ydb_generate_csr.sh first or use -k flag if CA generated the keys"
        exit 1
    fi
fi

# If CA cert not specified, try to find it in the certs directory
if [ -z "$CA_CERT" ]; then
    if [ -f "$CERTS_DIR/ca.crt" ]; then
        CA_CERT="$CERTS_DIR/ca.crt"
        echo "** Found CA certificate: $CA_CERT"
    fi
fi

echo "** Deploying certificates from: $CERTS_DIR"
if [ ! -z "$CA_CERT" ]; then
    echo "** CA certificate: $CA_CERT"
fi
echo ""

# Copy CA certificate to nodes directory if provided
if [ ! -z "$CA_CERT" ] && [ -f "$CA_CERT" ]; then
    cp "$CA_CERT" "nodes/ca.crt"
    echo "** Copied CA certificate to nodes/ca.crt"
    echo ""
fi

cert_count=0

# Process all certificate files in the directory
for cert_file in "$CERTS_DIR"/*.crt; do
    if [ -f "$cert_file" ]; then
        # Skip ca.crt
        cert_name=$(basename "$cert_file")
        if [ "$cert_name" = "ca.crt" ]; then
            continue
        fi
        
        # Extract node name (remove .crt extension)
        node_name=$(basename "$cert_file" .crt)
        
        # Create node directory if it doesn't exist
        if [ ! -d "nodes/$node_name" ]; then
            if [ "$COPY_KEYS" = true ]; then
                echo "** Creating directory for: $node_name"
                mkdir -p "nodes/$node_name"
            else
                echo "** Warning: Node directory not found for $node_name, skipping"
                continue
            fi
        fi
        
        # Handle private key
        if [ "$COPY_KEYS" = true ]; then
            # Copy key from certificates directory
            key_file="$CERTS_DIR/$node_name.key"
            if [ ! -f "$key_file" ]; then
                echo "** Warning: Key file not found: $key_file, skipping $node_name"
                continue
            fi
            echo "** Deploying certificate and key for: $node_name"
            cp "$key_file" "nodes/$node_name/node.key"
        else
            # Check if node key exists (generated locally)
            if [ ! -f "nodes/$node_name/node.key" ]; then
                echo "** Warning: Node key not found for $node_name, skipping"
                continue
            fi
            echo "** Deploying certificate for: $node_name"
        fi
        
        # Copy certificate to node directory as node.crt
        cp "$cert_file" "nodes/$node_name/node.crt"
        
        # Generate web.pem (node.key + node.crt + ca.crt if present)
        cat "nodes/$node_name/node.key" "nodes/$node_name/node.crt" > "nodes/$node_name/web.pem"
        if [ ! -z "$CA_CERT" ] && [ -f "$CA_CERT" ]; then
            cat "nodes/ca.crt" >> "nodes/$node_name/web.pem"
        fi
        
        cert_count=$((cert_count + 1))
    fi
done

if [ $cert_count -eq 0 ]; then
    echo "** Warning: No certificates were deployed"
    echo "** Make sure the certificates directory contains .crt files matching node names"
    exit 1
fi

echo ""
echo "** All done!"
echo "** Deployed $cert_count certificate(s)"
echo ""
echo "** Files in each node directory:"
echo "   - node.key (private key)"
echo "   - node.crt (signed certificate)"
echo "   - web.pem (combined: key + cert + ca)"
echo ""
if [ ! -z "$CA_CERT" ]; then
    echo "** CA certificate copied to: nodes/ca.crt"
    echo ""
fi
echo "** Node directories are ready for deployment"