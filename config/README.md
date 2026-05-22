# Parleq Managed Configuration Profile

`parleq-managed-example.mobileconfig` is a fully-formed macOS Configuration Profile that demonstrates how to govern Parleq via MDM. The example profile:

- Restricts the cleanup provider to **Azure OpenAI or OpenAI** (users can pick between them, but no other providers appear in the picker)
- Restricts the cleanup model to **GPT-4o or GPT-4o Mini**
- Disables **image-mode references** (no screenshots sent to the LLM — all references use OCR text mode)
- Disables the **file reference picker and drag-drop**
- Disables the **"Custom…" model entry** (users must pick from the curated list)
- Locks **auto-update off** (IT manages Parleq updates via package management)

Customize these values before deploying to your fleet. Remove any key you want to leave user-controlled — absent keys are not managed.

## Schema reference

Full schema documentation (all supported keys, types, and semantics) lives at:
**<https://parleq.app/docs/managed-configuration/>**

## How to import

### Jamf Pro

1. **Computers → Configuration Profiles → New**
2. Under the payload list, select **Application & Custom Settings**
3. Upload this `.mobileconfig` file (or paste the XML into the Custom Schema editor)
4. Set your scope (smart group, device group, or individual machines)
5. Click Save → the profile deploys on the next MDM check-in (typically within a few minutes)

### Kandji

1. **Library → Custom Profile → Add**
2. Upload this `.mobileconfig` file
3. Assign to a Blueprint or specific devices
4. The profile pushes on the next device sync

### Mosyle (Business or Manager)

1. **Apple Configurator → General → Custom Configuration Profile**
2. Upload this `.mobileconfig` file
3. Assign to a device group or individual devices

### Intune / Microsoft Endpoint Manager

1. **Devices → macOS → Configuration Profiles → Create profile**
2. Choose **Custom** as the profile type
3. Upload this `.mobileconfig` file
4. Assign to a group and deploy

### Any other MDM

All MDM platforms that speak the macOS MDM protocol accept the same `.mobileconfig` format. The profile targets `com.parleq.app` by placing the bundle identifier as a dictionary key inside the `com.apple.ManagedClient.preferences` payload's `PayloadContent`, with the policy values nested under `Forced → [{mcx_preference_settings: {...}}]` per Apple's managed-preferences spec.

## Verification

After deploying, confirm the profile took effect on a managed Mac:

```bash
# Check the managed preferences plist directly:
sudo plutil -p "/Library/Managed Preferences/com.parleq.app.plist"

# Or read individual keys:
defaults read com.parleq.app cleanupAllowedProviders
defaults read com.parleq.app imageReferenceEnabled
defaults read com.parleq.app autoUpdateEnabled
```

Parleq also logs a startup summary of detected managed keys to stderr
(visible via `log stream --predicate 'process == "Parleq"'` or via
`Console.app`). Use the **Menu Bar → View Managed Configuration…** dialog
to see all managed keys, their effective values, and their sources
(Managed / User / Default) — no Terminal required.

## Customizing UUIDs

The `PayloadUUID` and inner payload `PayloadUUID` values in this file are
example UUIDs. **You should replace them with freshly generated UUIDs** for
your own deployment to avoid conflicts if multiple profiles are pushed to
the same machine. Generate new ones in Terminal:

```bash
uuidgen  # for PayloadUUID (outer)
uuidgen  # for the inner payload PayloadUUID
```

Also replace the `PayloadIdentifier` strings (`com.parleq.managed-config.example`)
with your own organization's reverse-DNS prefix.
