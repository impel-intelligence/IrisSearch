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

### Supported Languages
- English

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

### Without any files from git LFS
swift test --skip lfs

## Embedding Models
Some default embeddings are provided in the regular `IrisSearch` package. More are provided in the `Embedders` package, which links to [swift-embeddings](https://github.com/jkrukowski/swift-embeddings/tree/main).

### CoreML Embedder
The CoreML embedder allows you to use a pre-compiled (`.mlmodelc`) file as an embedding model. This model *must* have the following inputs `input_ids (int32)`, `attention_mask (int32)`, `token_type_ids (int32)`. These are based on the input into BERT models.

#### CoreML Model Configuration
To configure the output of a CoreML model you *need* to provide a `config.json` file alongside your `.mlmodelc` file. You must also provide the `vocab.txt` for the model you are working with.

The config file should have the same structure and types as this json object:
```json
  {
    "tokenizerClass": "<tokenizer_class>",
    "maximumInputCharactersPerWord": int,
    "cleanText": true | false,
    "handleChineseCharacters": true | false,
    "stripAccents": true | false | null,
    "lowercase": true | false | null,
    "searchPrefix": "<search_prefix>" | null,
    "dimensions": int
}
```
1
