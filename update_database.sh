#!/usr/bin/env bash
set -o errexit
set -o pipefail
set -o nounset

# update_database.sh
# Usage: ./update_database.sh payments.csv database.txt
# Requirements implemented:
#  - CSV validation (header + per-line checks)
#  - Database backup (database.txt.bak)
#  - Logging to update_log.txt
#  - Summary report (summary_report.txt)
#  - Modular functions
#  - Graceful handling for missing files and invalid formats
#  - If CustomerID not found, append a new record with negative balance and log warning

LOG_FILE="update_log.txt"
SUMMARY_FILE="summary_report.txt"

# Utility: write timestamped log entry
log_message() {
  local level="$1"
  local msg="$2"
  printf '%s - %s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" >> "$LOG_FILE"
}

# Check file exists and is readable
check_file_exists() {
  local file="$1"
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    log_message "ERROR" "File '$file' not found or not readable."
    echo "ERROR: File '$file' not found or not readable." >&2
    exit 1
  fi
}

# Validate CSV header exactly matches expected header
validate_csv_header() {
  local csv="$1"
  local expected_header="CustomerID,Name,Amount,Date,PaymentChannel"
  local header
  header=$(head -n1 "$csv" | tr -d '\r\n')
  if [ "$header" != "$expected_header" ]; then
    log_message "ERROR" "Invalid CSV header in '$csv'. Expected: $expected_header ; Found: $header"
    echo "ERROR: Invalid CSV header. Expected: $expected_header" >&2
    exit 1
  fi
  log_message "INFO" "CSV header validated."
}

# Validate a CSV data line (CustomerID,Name,Amount,Date,PaymentChannel)
# - CustomerID: non-empty, digits
# - Amount: numeric (float), > 0
# - Date: YYYY-MM-DD
validate_csv_line() {
  local line_no="$1"
  local id="$2"
  local name="$3"
  local amount="$4"
  local date="$5"
  local channel="$6"

  if ! [[ "$id" =~ ^[0-9]+$ ]]; then
    log_message "ERROR" "Line $line_no: Invalid CustomerID: '$id'"
    return 1
  fi

  if ! [[ "$amount" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    log_message "ERROR" "Line $line_no: Invalid Amount: '$amount'"
    return 1
  fi

  if ! [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    log_message "ERROR" "Line $line_no: Invalid Date format (expected YYYY-MM-DD): '$date'"
    return 1
  fi

  # passed basic checks
  return 0
}

# Backup the database file
backup_database() {
  local db="$1"
  local backup="${db}.bak"
  cp -p -- "$db" "$backup"
  log_message "INFO" "Database backed up to '$backup'."
}

# Update database: subtract payment amounts from balances
# Database expected format: CustomerID,Name,Balance  (header line present)
# Produces an updated database in-place using a temporary file
update_database() {
  local csv="$1"
  local db="$2"

  # create temp file safely
  local tmpdb
  tmpdb="$(mktemp --suffix=.dbtmp)" || { log_message "ERROR" "Failed to create temp file."; exit 1; }

  # Preserve header of database
  head -n1 "$db" > "$tmpdb"

  # Build an associative map of payments: sum payments per CustomerID
  # Use awk to aggregate payments (handles multiple payments for same ID)
  # Skip header line:
  declare -A PAY_SUM
  declare -i total_lines=0
  declare -i processed=0
  total_amount_processed=0.0

  # Read CSV and validate lines, accumulate payments
  tail -n +2 "$csv" | nl -ba -w1 -s: | while IFS= read -r numbered_line; do
    # numbered_line looks like " 1:101,John Doe,100.50,2023-10-01,CLIQQ"
    line_no="${numbered_line%%:*}"
    line="${numbered_line#*:}"
    # parse CSV fields (simple split on comma; assumes names don't contain commas)
    IFS=',' read -r cid name amount date channel <<< "$line"
    # trim CR
    cid="${cid//$'\r'/}"
    name="${name//$'\r'/}"
    amount="${amount//$'\r'/}"
    date="${date//$'\r'/}"
    channel="${channel//$'\r'/}"

    total_lines=$((total_lines + 1))

    if ! validate_csv_line "$line_no" "$cid" "$name" "$amount" "$date" "$channel"; then
      log_message "ERROR" "Skipping line $line_no due to validation failure."
      continue
    fi

    # Accumulate payment (as decimal strings)
    # Use awk to perform decimal-friendly accumulation
    prev=$(awk -v id="$cid" 'BEGIN{print "0"}')
    # We'll accumulate via a temporary text file keyed by ID (since associative arrays inside while subshell could be tricky)
    printf '%s,%s\n' "$cid" "$amount" >> /tmp/__payments_accumulator.$$ 
    processed=$((processed + 1))
    # log the read
    log_message "INFO" "Queued payment: CustomerID=$cid Amount=$amount Date=$date Channel=$channel (CSV line $line_no)"
  done

  # Aggregate / sum payments per ID from accumulator
  declare -A SUMS
  if [ -f /tmp/__payments_accumulator.$$ ]; then
    while IFS=',' read -r cid amt; do
      # use awk for decimal addition
      old=${SUMS[$cid]:-0}
      SUMS[$cid]=$(awk -v a="$old" -v b="$amt" 'BEGIN{printf "%.2f", a + b}')
      total_amount_processed=$(awk -v t="$total_amount_processed" -v b="$amt" 'BEGIN{printf "%.2f", t + b}')
    done < /tmp/__payments_accumulator.$$
    rm -f /tmp/__payments_accumulator.$$
  fi

  # Now read database and subtract payments where applicable
  # database header already written to tmpdb
  tail -n +2 "$db" | while IFS=',' read -r dbid dbname dbbalance; do
    # trim CR
    dbid="${dbid//$'\r'/}"
    dbname="${dbname//$'\r'/}"
    dbbalance="${dbbalance//$'\r'/}"
    dbbalance_num=$(awk -v b="$dbbalance" 'BEGIN{printf "%.2f", b+0}')
    if [ -n "${SUMS[$dbid]:-}" ]; then
      payment="${SUMS[$dbid]}"
      # new balance = dbbalance - payment
      newbal=$(awk -v a="$dbbalance_num" -v b="$payment" 'BEGIN{printf "%.2f", a - b}')
      printf "%s,%s,%.2f\n" "$dbid" "$dbname" "$newbal" >> "$tmpdb"
      log_message "INFO" "Updated CustomerID=$dbid Name='$dbname' OldBalance=${dbbalance_num} Payment=${payment} NewBalance=${newbal}"
      # mark as applied
      SUMS[$dbid]="APPLIED"
    else
      # no payment for this id; copy as-is
      printf "%s,%s,%.2f\n" "$dbid" "$dbname" "$dbbalance_num" >> "$tmpdb"
    fi
  done

  # Handle payments for customer IDs not present in DB: append records with negative balance
  for id in "${!SUMS[@]}"; do
    if [ "${SUMS[$id]}" != "APPLIED" ]; then
      amt="${SUMS[$id]}"
      # When customer not found, create a placeholder name "UNKNOWN" and set balance = -amt
      newbal=$(awk -v b="$amt" 'BEGIN{printf "%.2f", 0 - b}')
      printf "%s,%s,%.2f\n" "$id" "UNKNOWN" "$newbal" >> "$tmpdb"
      log_message "WARN" "CustomerID=$id not found in DB. Appended new record with balance ${newbal} (payment ${amt})."
    fi
  done

  # Move tmpdb to original database file atomically
  mv "$tmpdb" "$db"
  log_message "INFO" "Database '$db' updated successfully."

  # Save global counters as files for summary generation
  echo "$total_lines" > /tmp/__update_total_lines.$$
  echo "$processed" > /tmp/__update_processed.$$
  echo "$total_amount_processed" > /tmp/__update_total_amount.$$
}

# Generate a summary report
generate_summary_report() {
  local csv="$1"
  local processed=0
  local total_lines=0
  local total_amount=0.00

  if [ -f /tmp/__update_total_lines.$$ ]; then
    total_lines=$(cat /tmp/__update_total_lines.$$)
    rm -f /tmp/__update_total_lines.$$
  fi
  if [ -f /tmp/__update_processed.$$ ]; then
    processed=$(cat /tmp/__update_processed.$$)
    rm -f /tmp/__update_processed.$$
  fi
  if [ -f /tmp/__update_total_amount.$$ ]; then
    total_amount=$(cat /tmp/__update_total_amount.$$)
    rm -f /tmp/__update_total_amount.$$
  fi

  echo "Payment Summary Report - $(date '+%Y-%m-%d %H:%M:%S')" > "$SUMMARY_FILE"
  echo "=========================================" >> "$SUMMARY_FILE"
  echo "CSV file: $csv" >> "$SUMMARY_FILE"
  echo "Total lines in CSV (excluding header): $total_lines" >> "$SUMMARY_FILE"
  echo "Payments processed: $processed" >> "$SUMMARY_FILE"
  echo "Total amount processed: $total_amount" >> "$SUMMARY_FILE"
  echo "" >> "$SUMMARY_FILE"
  echo "See $LOG_FILE for detailed per-customer updates and warnings." >> "$SUMMARY_FILE"

  log_message "INFO" "Summary report generated: $SUMMARY_FILE"
}

# Clean up function on exit
cleanup() {
  # remove any temporary accumulator file if it exists
  rm -f /tmp/__payments_accumulator.$$ /tmp/__update_total_lines.$$ /tmp/__update_processed.$$ /tmp/__update_total_amount.$$ 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------
# Main
# ---------------------------
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <payments.csv> <database.txt>" >&2
  exit 1
fi

CSV_FILE="$1"
DATABASE_FILE="$2"

# Initialize / rotate log file for this run
if [ ! -f "$LOG_FILE" ]; then
  echo "Update Log - $(date '+%Y-%m-%d %H:%M:%S')" > "$LOG_FILE"
else
  echo "" >> "$LOG_FILE"
  echo "---- New run at $(date '+%Y-%m-%d %H:%M:%S') ----" >> "$LOG_FILE"
fi

log_message "INFO" "Script started. CSV='$CSV_FILE' DB='$DATABASE_FILE'"

check_file_exists "$CSV_FILE"
check_file_exists "$DATABASE_FILE"
validate_csv_header "$CSV_FILE"

backup_database "$DATABASE_FILE"

update_database "$CSV_FILE" "$DATABASE_FILE"

generate_summary_report "$CSV_FILE"

log_message "INFO" "Script finished."

echo "Database updated successfully. See '$LOG_FILE' and '$SUMMARY_FILE' for details."
