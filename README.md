# Iris Search
Iris Search is a hybrid RAG system, that allows you to intake any form of content and turn it into text and natural language searchable content.

## Features
- Natural Language Search (Vector Search)
- Direct text search (FTS5 Text Search)
- The entire database is a single macOS package with the extension: `irisdb`
  - Easily transferrable between computers, just drag and drop a single file.

### Supported Formats
- PDF
- TXT (Generic for all plaintext formats)
- HTML
- XML
- OPML

## Installation
### Swift Package Manage
Add this package to your `Package.swift`:
```swift
.package(url: "https://github.com/impel-intelligence/IrisSearch", from: "2.2.0")
```

## Building
```swift
swift build
```

## Testing
Iris Search uses swift testing for all tests.

```swift
swift test
```

### Without Network
```swift
swift test --skip network
```
