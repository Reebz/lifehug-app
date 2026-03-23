---
title: "xcodebuild exportArchive fails with wrong teamID in ExportOptions.plist"
category: deployment-issues
tags:
  - xcodebuild
  - exportArchive
  - ExportOptions.plist
  - TestFlight
  - App Store Connect
  - code-signing
  - teamID
module: ios-distribution
symptom: "Archive succeeds but exportArchive fails with 'No Accounts with App Store Connect Access' and 'No Account for Team G65RLHQQUF'"
root_cause: "ExportOptions.plist contained the development team ID (G65RLHQQUF) instead of the App Store distribution certificate team ID (PJHS9XQS6H)"
date_solved: "2026-03-08"
severity: high
time_to_resolve: medium
---

# xcodebuild exportArchive Fails with Wrong teamID

## Symptom

`xcodebuild archive` succeeds, but `xcodebuild -exportArchive` fails with:

```
error: exportArchive No Accounts with App Store Connect Access
error: exportArchive No Account for Team "G65RLHQQUF"
```

Distribution logs show:
```
Failed to find an account with App Store Connect access for team <IDEProvisioningBasicTeam: ...; teamID='G65RLHQQUF', teamName='(null)'>
```

## Root Cause

The `teamID` in `ExportOptions.plist` did not match the team on the Apple Distribution certificate in Keychain. The project used team `G65RLHQQUF` for development signing, but the App Store distribution certificate was issued under team `PJHS9XQS6H`.

Xcode's export process looks up the App Store Connect account by team ID. When no account matches, it fails — even though the certificate and provisioning profile are otherwise valid.

## Diagnosis

### 1. Find the correct team ID

```bash
security find-identity -v -p codesigning | grep "Apple Distribution"
```

Output:
```
1) DCB7058C... "Apple Distribution: Mitchell Ribar (PJHS9XQS6H)"
```

The team ID is `PJHS9XQS6H` — the 10-character code in parentheses.

### 2. Check the distribution logs

```bash
find /var/folders -name "IDEDistribution.standard.log" 2>/dev/null | xargs ls -lt | head -3
```

Look for: `Failed to find an account with App Store Connect access for team`

### 3. Verify project.yml / project.pbxproj

The correct team ID (`PJHS9XQS6H`) is set as `DEVELOPMENT_TEAM` in `project.yml` line 45 and all `.xcodeproj` variants.

## Solution

### Working ExportOptions.plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>PJHS9XQS6H</string>
</dict>
</plist>
```

### Working command

```bash
xcodebuild -exportArchive \
  -archivePath ~/Desktop/Lifehug-build15.xcarchive \
  -exportOptionsPlist /tmp/ExportOptions.plist \
  -exportPath ~/Desktop/Lifehug-build15-export \
  -allowProvisioningUpdates
```

The `-allowProvisioningUpdates` flag is required for automatic signing — it permits xcodebuild to download and update provisioning profiles during export.

## Prevention

### Derive team ID dynamically

Never hardcode. Query the keychain before building ExportOptions.plist:

```bash
TEAM_ID=$(security find-identity -v -p codesigning \
  | grep "Apple Distribution" | head -1 \
  | sed 's/.*(\(.*\))/\1/')
```

### Pre-export validation

Compare the archive's team against ExportOptions.plist:

```bash
ARCHIVE_TEAM=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:Team" \
  "$ARCHIVE_PATH/Info.plist")
EXPORT_TEAM=$(/usr/libexec/PlistBuddy -c "Print :teamID" ExportOptions.plist)
if [ "$ARCHIVE_TEAM" != "$EXPORT_TEAM" ]; then
    echo "MISMATCH: Archive=$ARCHIVE_TEAM, Export=$EXPORT_TEAM"
    exit 1
fi
```

### Pre-upload checklist

- [ ] `security find-identity -v -p codesigning` — distribution cert present and not expired
- [ ] ExportOptions.plist teamID matches distribution cert team ID
- [ ] Archive team matches export team: `/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:Team" archive.xcarchive/Info.plist`
- [ ] Apple ID has App Manager/Admin role for the distribution team

## Common Pitfalls

1. **Multiple Apple Developer accounts**: Development and distribution certs may belong to different teams. The ExportOptions teamID must match the **distribution** certificate.
2. **Forgetting `-allowProvisioningUpdates`**: Without it, automatic signing can't refresh profiles.
3. **No ExportOptions.plist in repo**: This project generates it at export time — ensure the correct team ID is used each time.
