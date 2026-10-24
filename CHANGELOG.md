# ChangeLogs

## Unreleased

* Android: `readBytesAt` seeks to the offset instead of re-reading from the start (falls back to skipping for non-seekable providers)
* Progress events are sent at most once per whole percent (Android and iOS)
* Add `hashFile` (SHA-256 hex, streamed natively on Android and iOS)
* Android: `readFileBytes`, `readBytesAt`, `copyFileToPath` and `getFileMetadata` accept plain paths, `file://` and `content://` URIs
* Android: file operations use the application context, so they work without an Activity (background, activity recreation)
* Android: `getFileMetadata` returns `NO_CONTEXT` instead of crashing, and resolves tree URIs
* Android: `renameFile` accepts `destPath` for file paths; content URIs still require `newName`
* Android: `copyFileToPath` onto its own source is a no-op instead of truncating the file
* iOS: `checkAccess` keeps security-scoped access open while it checks the file
* Android: Robolectric tests for real `ContentResolver` reads

## 0.1.0

* Fix a bookmark issue preventing scan to detect files

## 0.1.0

* Run expensive operation on the background
* Introduced new methods (`readBytesAt`, `copyFileToPath`, `deleteFile`, `renameFile`, `exists` and `releasePermission`)
* Improve overall code and docs

## 0.0.5

- removed storageType support
- run scan in queue
- improved the parent bookmark lookup
- made the checkAccess better at dealing with bookmakr
- checkaccess now works with file/directory

## 0.0.4

- add `checkAccess`
- improve ios bookmarks to support diffrent storage providers

## 0.0.3

- add `readFileBytes`
- add missing uri from `SAFFile`

## 0.0.2

- add `scanDirectory`
- persisted access for IOS and Android


## 0.0.1

- plugin initial setup
- introduced `pickDirectory`
