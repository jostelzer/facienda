# Third-party notices

## Built-in memory

- **Hindsight** 0.10.2 — https://github.com/vectorize-io/hindsight — MIT License, Copyright (c) Vectorize AI, Inc.
  Facienda's built-in memory follows Hindsight's retain, consolidation and recall method, and its extraction,
  consolidation and merge prompts (`Sources/FaciendaCore/MemoryPrompts.swift`) are adapted from Hindsight's.
- **BAAI/bge-small-en-v1.5** — https://huggingface.co/BAAI/bge-small-en-v1.5 — MIT License.
  Converted to Core ML with 8-bit weights as `Sources/FaciendaCore/Resources/Memory/MemoryEmbedder.mlpackage`.
- **cross-encoder/ms-marco-MiniLM-L-6-v2** — https://huggingface.co/cross-encoder/ms-marco-MiniLM-L-6-v2 — Apache License 2.0.
  Converted to Core ML with 8-bit weights as `Sources/FaciendaCore/Resources/Memory/MemoryReranker.mlpackage`.
  `vocab.txt` is the shared uncased BERT WordPiece vocabulary of both models.

The conversion is reproducible with `scripts/convert_memory_models.py`.

## Full notices

Full upstream license texts and dependency notices are retained in [Support/ThirdPartyNotices.txt](Support/ThirdPartyNotices.txt) and bundled with the Mac app.

The conversion script pins the cached upstream model snapshots. The existing converted model weights are preserved unchanged; this source cleanup does not regenerate them.
