# TrueNAS SCALE App Auto Updater

A small Bash script for automating TrueNAS SCALE App upgrades while preserving the original running/stopped state of each App.

> **Important:** This is a community script, not an official TrueNAS tool. Review the script and test it in your own environment before using it for production workloads.

## What it does

- Finds TrueNAS Apps with `upgrade_available == true`.
- Processes Apps one at a time.
- Temporarily starts an App if it was originally `STOPPED`.
- Runs the App upgrade job and waits for completion.
- Restores an originally stopped App to `STOPPED` after the upgrade.
- Leaves originally running Apps running.
- Does not manipulate Apps in unexpected/transitional states; those Apps are reported as skipped.
- Stops starting new upgrades after a configurable deadline.
- Records activity in a log file.
- Can submit an email report using the SMTP configuration already stored in TrueNAS.

## Requirements

The script expects a TrueNAS SCALE system with:

- `midclt`
- `jq`
- TrueNAS Apps using the middleware App API
- Root privileges (recommended for a TrueNAS Cron Job)
- A configured TrueNAS email/SMTP service if email reporting is desired

## Configuration

The script uses environment variables so no personal email address or secret is stored in the repository:

```bash
UPDATE_DEADLINE="02:45"
MAIL_TO="admin@example.com"
LOG_FILE="/root/truenas-app-update.log"
```

Defaults are:

- `UPDATE_DEADLINE=02:45`
- `MAIL_TO` empty (no email is sent)
- `LOG_FILE=/root/truenas-app-update.log`

### Manual run

```bash
chmod +x truenas-app-auto-updater.sh

UPDATE_DEADLINE="02:45" \
MAIL_TO="admin@example.com" \
./truenas-app-auto-updater.sh
```

### TrueNAS GUI Cron Job

Create a Cron Job in TrueNAS and run it as `root`.

Example command:

```bash
UPDATE_DEADLINE="02:45" MAIL_TO="admin@example.com" /root/truenas-app-auto-updater.sh
```

Choose a schedule that gives the updater enough time to finish before the configured deadline. For example, if a separate reboot is scheduled for 03:00, a 21:00 daily App-update job with a `02:45` deadline provides a five-hour maintenance window.

**Do not create the same scheduled job both in the TrueNAS GUI and in the root user's `crontab`; otherwise it can run twice.**

## Email reporting

The script does not contain an SMTP password. It calls TrueNAS `mail.send`, so the TrueNAS system's configured SMTP settings are used.

If `MAIL_TO` is empty, updates still run and the log is still written, but no email report is sent.

## Safety behavior

Before each upgrade, the script checks the App's current state.

- `RUNNING` → upgrade → remains `RUNNING`
- `STOPPED` → start → upgrade → stop → remains `STOPPED`
- Other/unexpected state → skip and report it

If starting a stopped App fails, the upgrade is not attempted. If the upgrade fails after a stopped App was started, the script still attempts to restore that App to `STOPPED`.

The deadline prevents **new** upgrades from being started after the configured time. An upgrade already in progress is allowed to finish; it is not forcibly aborted at the deadline.

Upgrades can fail because of network problems, catalog problems, incompatible versions, storage issues, application-specific failures, or other TrueNAS conditions. Always review the generated log after the first few runs.

Do not put SMTP passwords, API keys, tokens, private IP addresses, domain names, or other secrets into this repository.

## Example report

```text
TrueNAS App Update Report

Started: 2026-08-17 23:12:38
Finished: 2026-08-17 23:19:32

SUCCESSFUL UPDATES:
SUCCESS: elastic-search  1.4.15 -> 1.4.17
SUCCESS: photoprism      1.4.9 -> 1.4.10

FAILED / ABORTED:
None

RESTORED STOPPED APPS:
elastic-search restored to STOPPED
photoprism restored to STOPPED
```

## Tested environment

The project was developed and tested by the repository author on a TrueNAS SCALE installation, including upgrades of stopped Apps followed by restoration to `STOPPED`. Exact behavior can vary between TrueNAS SCALE releases and App versions because the middleware API and App implementation may change.

## License

MIT License. See `LICENSE`.
