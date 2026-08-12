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

## Benchmarking
`IrisBenchmark` is a standalone executable that measures what it costs to put documents into an
`IrisDB` and to get them back out. It is not a test target: a full run ingests thousands of documents
over many minutes and writes result artifacts, neither of which belongs in `swift test`.

```sh
swift run -c release IrisBenchmark --corpus /path/to/documents
```

Always build with `-c release`. A debug build is several times slower and the tool will warn you.

### What it measures
At each configured corpus size, on a single database that grows through them all:

| | |
| --- | --- |
| Intake | Per-document `createDocument` latency and chunks/second, as a function of how much is already in the database |
| Search | Warm `search(query:)` p50/p90/p99, split out by query shape |
| Cold search | The first query against a freshly opened `IrisDB`, which pays FAISS index deserialization |
| Single-document search | `search(within:)`, which should stay flat as the library grows |
| Attribution | How much of search latency is query embedding versus retrieval |
| Storage | SQLite, global index and per-document index sizes, plus process memory |
| Digestion | `Digester` throughput per source format |
| Mutation | `updateDocument` and `deleteDocument` on a full-size database |
| Parallel intake | Throughput at several concurrency levels |

It fits a power law to the checkpoint rows and reports the exponent, so intake and search each get a
stated scaling behaviour rather than a single number.

### Corpus
Point `--corpus` at one or more directories; it is repeatable. Everything a registered digester
claims is used. Digested chunks are cached on disk keyed by path, size, modification date and
`--context-size`, so re-running against the same corpus skips digestion entirely.

Real corpora top out in the hundreds of documents, well short of the library a researcher
accumulates. Past the number of real files, the tool pads the corpus with documents assembled from
contiguous runs of chunks resampled out of the real material, keeping chunk lengths, vocabulary and
per-document chunk counts realistic. Pass `--no-synthetic` to stop at the real document count.

### Embedders
`--embedder nl` (default), `contextual`, `coreml --coreml-model <dir>`, or `hash`.

`hash` is a deterministic feature-hashing embedder that costs microseconds. Its vectors are
meaningless, so it is useless for judging result quality — but it removes the embedding model from
the measurement almost entirely, which is what you want when the question is how SQLite and FAISS
scale rather than how fast the model is. Quote search latency from a real provider, not from `hash`.

### Cost
`FaissIndex` rewrites the entire global index file on every insert, so the bytes a run writes grow
with the square of the document count. The default top checkpoint is 2,000 documents for that
reason. Raising `--checkpoints` is deliberate, not free: doubling the top checkpoint roughly
quadruples the disk written.

List-valued flags take space-separated values:

```sh
swift run -c release IrisBenchmark --corpus ~/Papers \
  --checkpoints 100 500 1000 --top-k 5 10 25 --concurrency 1 4 8
```

Pass `--no-concurrency` to skip the parallel intake phase.

### Output
Written to `--output` (default `./BenchmarkResults`):

- `results.json` — the full result set, for diffing runs against each other
- `summary.md` — every table as Markdown, plus the caveats that apply to the run
- `intake-series.csv` — one row per ingested document, for plotting the intake curve

Run `swift run -c release IrisBenchmark --help` for the full flag list.

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
