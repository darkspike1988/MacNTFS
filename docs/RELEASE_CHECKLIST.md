# Release checklist

Keep a release candidate unpublished until the applicable gates below have evidence. This checklist documents required work; unchecked items are not claims of completion.

## Source and documentation

- [ ] Review the complete staged diff and all newly tracked files for private data, secrets, binary analysis extracts, and incompatible source licenses.
- [ ] Retain all required copyright and license notices. Confirm the repository's MIT license matches the source actually distributed.
- [ ] Match README features and limitations to the final implementation and validation results.
- [ ] Check the public website in `docs/index.html` and release notes for outdated claims.
- [ ] Select a new version consistently across the tag, app metadata, package name, and release notes.

## Filesystem verification

- [ ] Run `swift test` and `swift build -c release` on the final commit.
- [ ] Validate formatted images with an independent NTFS reader/checker, including required system files and allocation metadata.
- [ ] Verify file creation and content hashes, directory/MFT growth, fragmented allocation, duplicate rejection, and error handling.
- [ ] On the designated disposable 8 GB USB stick, repeat native formatting and file transfers for multiple complete cycles. Record device identity and results for each cycle.
- [ ] Eject, reconnect, reopen, and compare file hashes after each USB cycle.
- [ ] Verify that the drive appears under Finder Locations and record the filesystem implementation responsible for the mount.
- [ ] For independent write-mount support, test the packaged filesystem extension with competing filesystem extensions inactive, including activation, copy, reopen, eject, and reconnect.
- [ ] Verify interoperability on Windows before claiming Windows production compatibility.

## Package and permissions

- [ ] Bundle the exact app, CLI helper, resources, and any filesystem extension built from the final commit.
- [ ] Verify the actual Mach-O architecture matches the advertised artifact name. The current DMG script names its output `arm64` but builds for the host architecture.
- [ ] Test the minimum supported macOS version; document any higher requirement for the filesystem extension.
- [ ] Test the installed app's authorization path on a machine without local helper or sudo configuration.
- [ ] For signed distribution, configure an Apple Developer team and Developer ID Application signing identity, with the required profiles and entitlements for every embedded executable and extension.
- [ ] Sign embedded components and the outer app, enable the hardened runtime as appropriate, and verify code signatures and Gatekeeper assessment.
- [ ] Submit the final distribution artifact for notarization with configured credentials; staple and validate the ticket.
- [ ] Mount the final DMG, install its app, and repeat the basic user path from that exact artifact. Generate a SHA-256 checksum for the final downloadable file.

## GitHub publication

The existing `.github/workflows/release.yml` publishes on every pushed `v*` tag. It has `contents: write` permission and uses the repository's `GITHUB_TOKEN`; pushing a release tag is a publication action.

- [ ] Ensure CI passes for the final commit. The release workflow currently builds a DMG without running tests itself.
- [ ] Add signing/notarization and required extension packaging before advertising a signed, independently mountable distribution. The current script does not perform those steps.
- [ ] Confirm repository write access and workflow permissions. Keep signing certificates, passwords, and notarization credentials in an appropriate secrets store, never in source control.
- [ ] Review the release title, notes, known limitations, artifact architecture, and checksum before pushing a release tag.
- [ ] Commit and push the reviewed source; then push the intended version tag only after all release gates pass.
- [ ] Verify the resulting workflow run, public release, downloadable artifact, and checksum. Install the downloaded artifact for a final smoke test.
