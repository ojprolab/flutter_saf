# ChangeLogs

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
