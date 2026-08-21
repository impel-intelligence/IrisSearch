# Test documents

<!-- Edited by Claude Opus 5 (Anthropic) on 2026-08-17 -->

Fixtures the IrisSearch test suite digests, indexes, and searches. This file records where each one came from, because the repository is public and some of them are not ours.

## Removed: `Arxiv/`

This directory previously held 50 papers downloaded from arXiv. It has been removed from the repository and from its history.

arXiv's default submission license grants arXiv a licence to distribute, and does not grant third parties the right to redistribute. Individual papers are sometimes released under CC-BY or similar, but that varies per paper and was not tracked here. Publishing them alongside this repository would have been redistribution we had no clear right to perform.

Two tests digest a bulk PDF corpus and now **skip automatically** when none is present:

- `Tests/IntegrationTests/SearchIntegrationTests.swift` — index-and-search performance
- `Tests/DigesterTests/PDFTests.swift` — "Speed Small PDFS"

To run them, drop any collection of PDFs into `Tests/Test Documents/Arxiv/`. The contents do not matter; the tests only need a directory of real PDFs. Papers explicitly licensed CC-BY on arXiv are a good source if you want the original shape of the corpus. Files placed there are gitignored.

## Kept fixtures

| Path | Origin | Licence |
|---|---|---|
| `html/` | Written for this project | Apache-2.0, as the repository |
| `Markdown/syntax-test.md` | Written for this project | Apache-2.0, as the repository |
| `pdf/long-pdf-test.pdf` | Written for this project | Apache-2.0, as the repository |
| `pdf/pdf-ingestion-test-suite.pdf` | Written for this project | Apache-2.0, as the repository |
| `pdf/simple-pdf-feature-test.pdf` | Written for this project | Apache-2.0, as the repository |
| `txt/Lorem.txt` | Lorem ipsum filler | No rights asserted |
| `txt/Shakespeare.txt` | Complete works of Shakespeare | Public domain |
| `Sonnets/` | Shakespeare's sonnets, one per file | Public domain |
| `pdf/X86_Disassembly.pdf` | [WikiBooks, *x86 Disassembly*](https://en.wikibooks.org/wiki/X86_Disassembly) | CC BY-SA 3.0 |
| `pdf/somatosensory.pdf` | Widely circulated sample PDF, believed derived from Wikipedia content | Believed CC BY-SA — see note |
| `ml/bge/` | [BAAI/bge-small-en-v1.5](https://huggingface.co/BAAI/bge-small-en-v1.5) | MIT |

### Note on the two CC BY-SA PDFs

`X86_Disassembly.pdf` and `somatosensory.pdf` are redistributable with attribution, which this file provides. They are test data rather than part of the software, so the share-alike term attaches to those files and not to the project — the Apache-2.0 licence on the code is unaffected.

`somatosensory.pdf` is a sample document that circulates widely in PDF tooling test suites. Its exact provenance has not been confirmed; it is recorded here as probably Wikipedia-derived and therefore probably CC BY-SA. If that matters to you, replace it rather than relying on this note.

## Large files

`long-pdf-test.pdf` is roughly 72MB and is stored directly in git rather than Git LFS. Only `ml/bge/` is LFS-tracked. Anyone cloning this repository pays for that once.
