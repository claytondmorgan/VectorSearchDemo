#!/bin/bash
set -e

#
# Sets up the legal_documents table in the RDS database.
# Pulls DB credentials from AWS Secrets Manager and runs schema_legal.sql.
#
# Prerequisites:
#   - AWS CLI configured with appropriate permissions
#   - psql (PostgreSQL client) installed
#   - schema_legal.sql in the same directory
#
# Usage:
#   ./setup-legal-db.sh
#

AWS_REGION=us-east-1
SECRET_NAME=llm-db-credentials
SCHEMA_FILE="$(dirname "$0")/schema_legal.sql"

echo "=============================================="
echo "Legal Documents — Database Setup"
echo "=============================================="
echo ""

# Verify schema file exists
if [ ! -f "$SCHEMA_FILE" ]; then
    echo "ERROR: schema_legal.sql not found at $SCHEMA_FILE"
    exit 1
fi

# Verify psql is available
if ! command -v psql &> /dev/null; then
    echo "ERROR: psql (PostgreSQL client) is not installed."
    echo "Install with: brew install postgresql"
    exit 1
fi

# Pull DB credentials from Secrets Manager
echo "Fetching database credentials from AWS Secrets Manager..."
SECRET_JSON=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_NAME" \
    --region "$AWS_REGION" \
    --query 'SecretString' \
    --output text)

DB_HOST=$(echo "$SECRET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['host'])")
DB_PORT=$(echo "$SECRET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['port'])")
DB_NAME=$(echo "$SECRET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['database'])")
DB_USER=$(echo "$SECRET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")
DB_PASS=$(echo "$SECRET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

echo "  Host: $DB_HOST"
echo "  Port: $DB_PORT"
echo "  Database: $DB_NAME"
echo "  User: $DB_USER"
echo ""

# Check if legal_documents table already exists
echo "Checking if legal_documents table already exists..."
TABLE_EXISTS=$(PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'legal_documents');" 2>/dev/null)

if [ "$TABLE_EXISTS" == "t" ]; then
    echo "  Table legal_documents already exists."
    EXISTING_COUNT=$(PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
        "SELECT COUNT(*) FROM legal_documents;" 2>/dev/null)
    echo "  Current row count: $EXISTING_COUNT"
    echo ""
    read -p "Drop and recreate the table? (y/N): " RECREATE
    if [ "$RECREATE" == "y" ] || [ "$RECREATE" == "Y" ]; then
        echo "Dropping existing table..."
        PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c \
            "DROP TABLE IF EXISTS legal_documents CASCADE;"
        echo "  Dropped."
    else
        echo "Keeping existing table. Running schema (CREATE IF NOT EXISTS)..."
    fi
fi

# Run the schema SQL
echo ""
echo "Running schema_legal.sql..."
PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$SCHEMA_FILE"

echo ""
echo "Verifying table creation..."
VERIFY=$(PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'legal_documents';")
echo "  legal_documents table has $VERIFY columns."

# Show index info
echo ""
echo "Indexes created:"
PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c \
    "SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'legal_documents' ORDER BY indexname;"

echo ""
echo "=============================================="
echo "Database setup complete!"
echo "=============================================="
echo ""
echo "Next steps:"
echo "  1. Ingest legal documents via the Python service: POST /legal/ingest"
echo "  2. Deploy the Java service: ./redeploy.sh"
echo "  3. Test legal endpoints: ./test-legal-api.sh http://llm-alb-1402483560.us-east-1.elb.amazonaws.com"