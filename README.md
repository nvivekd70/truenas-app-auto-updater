# TrueNAS SCALE App Auto Updater

A small Bash script for automating TrueNAS SCALE App upgrades while preserving the original running/stopped state of each App.

> **Important:** This is a community script, not an official TrueNAS tool. Review the script and test it in your own environment before using it for production workloads.

## What it does

- Finds TrueNAS Apps with an available upgrade.
- Processes Apps one at a time.
- Temporarily starts an App if it was originally stopped.
- Runs the App upgrade job.
- Restores an originally stopped App to `STOPPED` after the upgrade.
- Leaves originally running Apps running.
- Stops starting new upgrades after a configurable deadline.
- Records activity in a log file.
- Can submit an email report using TrueNAS `mail.send`.

## Configuration

The script can be configured through environment variables:

```bash
export UPDATE_DEADLINE="02:45"
export MAIL_TO="admin@example.com"
export LOG_FILE="/root/truenas-app-update.log"
```

If `MAIL_TO` is empty, the script still performs the updates and writes the log, but does not send an email.

## Requirements

The script expects the following TrueNAS SCALE utilities:

- `midclt`
- `jq`
- TrueNAS Apps using the middleware App API

It is intended to be run with sufficient privileges to manage Apps.

## Example

```bash
chmod +x truenas-app-auto-updater.sh

export UPDATE_DEADLINE="02:45"
export MAIL_TO="admin@example.com"

./truenas-app-auto-updater.sh
```

For a scheduled TrueNAS job, configure the schedule so that the script has enough time to complete before the desired deadline.

## Safety notes

The script uses the App state returned by TrueNAS before each upgrade. If an App was `STOPPED`, it is started only for the upgrade and then an attempt is made to return it to `STOPPED`.

Upgrades can fail because of network problems, catalog problems, incompatible versions, storage issues, application-specific failures, or other TrueNAS conditions. Always review the generated log after the first few runs.

Do not put SMTP passwords, API keys, tokens, private IP addresses, domain names, or other secrets into this repository.

## Tested environment

The project was developed and tested by the repository author on a TrueNAS SCALE installation. Exact behavior can vary between TrueNAS SCALE releases and App versions because the middleware API and App implementation may change.

## License

MIT License. See `LICENSE`.
