# 1. Generate keys and CSRs
./ydb_generate_csr.sh -o YDB

# 2. Sign with self-signed CA
./ydb_self_sign.sh

# 3. Deploy certificates to node directories
./ydb_arrange_certs.sh -d certs/$(ls -t certs | head -1)