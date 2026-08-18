#!/bin/bash

# TrueNAS SCALE App Auto Updater
#
# Safely updates Apps reported by TrueNAS as having an available upgrade.
# - Updates one App at a time.
# - Temporarily starts Apps that were STOPPED, then restores STOPPED state.
# - Leaves RUNNING Apps running.
# - Stops starting new upgrades after the configured deadline.
# - Writes a log and can send an email report through TrueNAS mail.send.
#
# Tested by the author on TrueNAS SCALE with midclt + jq.
# This is a community script, not an official TrueNAS tool.

set -u
set -o pipefail

# -----------------------------
# Configuration
# -----------------------------
LOG_FILE="${LOG_FILE:-/root/truenas-app-update.log}"
UPDATE_DEADLINE="${UPDATE_DEADLINE:-02:45}"
MAIL_TO="${MAIL_TO:-}"  # Example: admin@example.com
SLEEP_START=15
SLEEP_UPGRADE=30

MIDCLT="/usr/bin/midclt"
JQ="/usr/bin/jq"

SUCCESS_LIST=""
FAILED_LIST=""
RESTORED_LIST=""

# Basic dependency check before doing anything destructive.
for command in "$MIDCLT" "$JQ"; do
    if [ ! -x "$command" ]; then
        echo "ERROR: Required command not found or not executable: $command" >&2
        exit 1
    fi
done

START_TIME=$(date '+%Y-%m-%d %H:%M:%S')

# The normal use case is a nightly run before a maintenance reboot. The
# deadline is the next occurrence of UPDATE_DEADLINE, normally tomorrow.
DEADLINE=$(date -d "tomorrow ${UPDATE_DEADLINE}" +%s)

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $*" >> "$LOG_FILE"
}

append_line() {
    local var_name="$1"
    local line="$2"

    if [ -n "${!var_name}" ]; then
        printf -v "$var_name" '%s\n%s' "${!var_name}" "$line"
    else
        printf -v "$var_name" '%s' "$line"
    fi
}

send_report() {
    local subject="$1"
    local text="$2"
    local payload

    if [ -z "$MAIL_TO" ]; then
        log "MAIL_TO is empty; email report not sent."
        return 0
    fi

    # Build valid JSON with jq rather than manually escaping JSON.
    payload=$("$JQ" -n \
        --arg subject "$subject" \
        --arg text "$text" \
        --arg to "$MAIL_TO" \
        '{subject:$subject, text:$text, to:[$to]}')

    if ! "$MIDCLT" call mail.send "$payload" >> "$LOG_FILE" 2>&1; then
        log "WARNING: mail.send failed."
        return 1
    fi

    return 0
}

get_app_info() {
    local app="$1"
    "$MIDCLT" call app.query | "$JQ" -r --arg APP "$app" \
        '.[] | select(.name==$APP) | {state,version,latest_version}'
}

wait_for_job() {
    local job_id="$1"
    local sleep_time="$2"

    while true; do
        local job_info state
        job_info=$("$MIDCLT" call core.get_jobs "[[\"id\",\"=\",$job_id]]")
        state=$(echo "$job_info" | "$JQ" -r '.[0].state // "UNKNOWN"')

        case "$state" in
            SUCCESS)
                return 0
                ;;
            FAILED|ABORTED)
                echo "$job_info"
                return 1
                ;;
            *)
                sleep "$sleep_time"
                ;;
        esac
    done
}

log "========================================"
log "TrueNAS App Update Started: $START_TIME"
log "========================================"

APPS=$("$MIDCLT" call app.query | \
    "$JQ" -r '.[] | select(.upgrade_available == true) | .name')

if [ -z "$APPS" ]; then
    END_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    log "No App updates available."

    EMAIL_TEXT="TrueNAS App Update Report

Started: $START_TIME
Finished: $END_TIME

No App updates were available.

Update deadline: $UPDATE_DEADLINE
"

    send_report "TrueNAS App Update - No Updates" "$EMAIL_TEXT"
    exit 0
fi

log "Apps with updates:"
while read -r app; do
    [ -n "$app" ] && log "  $app"
done <<< "$APPS"

while read -r APP; do
    [ -z "$APP" ] && continue

    NOW=$(date +%s)
    if [ "$NOW" -ge "$DEADLINE" ]; then
        log "Deadline $UPDATE_DEADLINE reached. No more updates will be started."
        break
    fi

    log "Processing $APP"

    APP_INFO=$(get_app_info "$APP")
    ORIGINAL_STATE=$(echo "$APP_INFO" | "$JQ" -r '.state')
    OLD_VERSION=$(echo "$APP_INFO" | "$JQ" -r '.version')
    LATEST_VERSION=$(echo "$APP_INFO" | "$JQ" -r '.latest_version')

    log "$APP state=$ORIGINAL_STATE version=$OLD_VERSION latest=$LATEST_VERSION"

    # Only RUNNING and STOPPED are safe/expected states for this workflow.
    # Do not try to manipulate an App in a transitional/error state.
    if [ "$ORIGINAL_STATE" != "RUNNING" ] && [ "$ORIGINAL_STATE" != "STOPPED" ]; then
        log "SKIPPED: $APP is in unsupported state $ORIGINAL_STATE"
        append_line FAILED_LIST "SKIPPED: $APP - Unsupported state: $ORIGINAL_STATE"
        continue
    fi

    # Temporarily start a stopped App.
    if [ "$ORIGINAL_STATE" = "STOPPED" ]; then
        log "$APP is STOPPED; starting temporarily."

        START_JOB=$("$MIDCLT" call app.start "$APP" 2>&1)

        if ! [[ "$START_JOB" =~ ^[0-9]+$ ]]; then
            log "FAILED to start $APP: $START_JOB"
            append_line FAILED_LIST "FAILED: $APP - Could not start"
            continue
        fi

        log "$APP start job ID: $START_JOB"

        if ! START_RESULT=$(wait_for_job "$START_JOB" "$SLEEP_START"); then
            ERROR=$(echo "$START_RESULT" | "$JQ" -r '.[0].error // "Unknown error"')
            log "FAILED to start $APP: $ERROR"
            append_line FAILED_LIST "FAILED: $APP - Start failed: $ERROR"
            continue
        fi

        log "$APP started successfully."
    fi

    # Upgrade the App.
    log "Starting upgrade for $APP"

    UPGRADE_JOB=$("$MIDCLT" call app.upgrade "$APP" '{"app_version":"latest"}' 2>&1)

    if ! [[ "$UPGRADE_JOB" =~ ^[0-9]+$ ]]; then
        log "FAILED to start upgrade for $APP: $UPGRADE_JOB"
        append_line FAILED_LIST "FAILED: $APP - Upgrade could not start"
    else
        log "$APP upgrade job ID: $UPGRADE_JOB"

        if UPGRADE_RESULT=$(wait_for_job "$UPGRADE_JOB" "$SLEEP_UPGRADE"); then
            NEW_VERSION=$("$MIDCLT" call app.query | "$JQ" -r --arg APP "$APP" \
                '.[] | select(.name==$APP) | .version')
            log "SUCCESS: $APP updated $OLD_VERSION -> $NEW_VERSION"
            append_line SUCCESS_LIST "SUCCESS: $APP  $OLD_VERSION -> $NEW_VERSION"
        else
            ERROR=$(echo "$UPGRADE_RESULT" | "$JQ" -r '.[0].error // "Unknown error"')
            log "FAILED: $APP - $ERROR"
            append_line FAILED_LIST "FAILED: $APP - $ERROR"
        fi
    fi

    # Restore original stopped state.
    if [ "$ORIGINAL_STATE" = "STOPPED" ]; then
        log "Restoring $APP to STOPPED state."

        STOP_JOB=$("$MIDCLT" call app.stop "$APP" 2>&1)

        if ! [[ "$STOP_JOB" =~ ^[0-9]+$ ]]; then
            log "WARNING: Could not stop $APP: $STOP_JOB"
            append_line FAILED_LIST "WARNING: $APP could not be restored to STOPPED"
        else
            log "$APP stop job ID: $STOP_JOB"

            if wait_for_job "$STOP_JOB" "$SLEEP_START" >/dev/null; then
                log "$APP restored to STOPPED."
                append_line RESTORED_LIST "$APP restored to STOPPED"
            else
                log "WARNING: Failed to restore $APP to STOPPED."
                append_line FAILED_LIST "WARNING: $APP could not be restored to STOPPED"
            fi
        fi
    fi

done <<< "$APPS"

END_TIME=$(date '+%Y-%m-%d %H:%M:%S')

log "========================================"
log "TrueNAS App Update Finished: $END_TIME"
log "========================================"

EMAIL_TEXT="TrueNAS App Update Report

Started: $START_TIME
Finished: $END_TIME

SUCCESSFUL UPDATES:
${SUCCESS_LIST:-None}

FAILED / ABORTED:
${FAILED_LIST:-None}

RESTORED STOPPED APPS:
${RESTORED_LIST:-None}

Update deadline: $UPDATE_DEADLINE

Full log:
$LOG_FILE"

send_report "TrueNAS App Update Report - $(date '+%Y-%m-%d')" "$EMAIL_TEXT"
log "Email report submitted (if MAIL_TO is configured)."
