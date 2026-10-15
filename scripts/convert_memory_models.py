#!/usr/bin/env python3
"""Convert Facienda's built-in memory models to Core ML.

Embeddings: BAAI/bge-small-en-v1.5 (MIT), CLS pooling, L2-normalized, 384 dims.
Reranker: cross-encoder/ms-marco-MiniLM-L-6-v2 (Apache-2.0), one relevance logit.
Both use the same uncased BERT WordPiece vocabulary, copied next to the models.

Needs torch, transformers and coremltools. Weights are quantized to 8 bits and
the outputs are checked against the original PyTorch models before saving.
"""
import argparse
import shutil
import sys
from pathlib import Path

import coremltools as ct
import coremltools.optimize as cto
import numpy as np
import torch

torch.set_grad_enabled(False)
from transformers import AutoModel, AutoModelForSequenceClassification, AutoTokenizer

EMBEDDER = "BAAI/bge-small-en-v1.5"
RERANKER = "cross-encoder/ms-marco-MiniLM-L-6-v2"
# Hugging Face commit hashes (40 hex characters) of the exact model snapshots to convert. Without them
# from_pretrained follows the mutable "main" branch, so a changed upstream repository would flow into the
# bundled Core ML models unreviewed.
# Pinned to the upstream snapshots available in the local conversion cache when this source snapshot was prepared.
EMBEDDER_REVISION = "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a"
RERANKER_REVISION = "233902d25c440f23af6f7d6e94d2946bac0bee0a"
MAX_TOKENS = 512
# The reranker scores a fixed batch of pairs padded to one of these lengths; fixed shapes run well on the Neural Engine.
RERANK_BATCH = 16
RERANK_LENGTHS = [64, 128, 256, 512]
SAMPLES = [
    ("What camera recording frame rate did we test?", "Nine physical cameras recorded at 1920x1200 and 40 FPS with zero missing frames."),
    ("Which license did we pick?", "Facienda will be open-sourced under the Apache-2.0 license."),
    ("desk lamp order", "The desk lamp was quoted at 89 euros including VAT."),
    ("short", "User prefers clean and polished implementations."),
]


class Bert(torch.nn.Module):
    """Plain BERT encoder with the original weights, written with traceable ops only."""

    def __init__(self, hf, batch=1):
        super().__init__()
        c = hf.config
        self.batch = batch
        self.heads, self.width = c.num_attention_heads, c.hidden_size
        self.size = self.width // self.heads
        self.hf = hf

    def forward(self, input_ids, attention_mask, token_type_ids):
        e = self.hf.embeddings
        positions = torch.cumsum(torch.ones_like(input_ids), dim=1) - 1
        x = e.word_embeddings(input_ids) + e.position_embeddings(positions) + e.token_type_embeddings(token_type_ids)
        x = e.LayerNorm(x)
        bias = (1.0 - attention_mask.float())[:, None, None, :] * -1e4
        h, s, d = self.heads, self.size, self.width
        for layer in self.hf.encoder.layer:
            a = layer.attention
            q = a.self.query(x).reshape(self.batch, -1, h, s).transpose(1, 2)
            k = a.self.key(x).reshape(self.batch, -1, h, s).transpose(1, 2)
            v = a.self.value(x).reshape(self.batch, -1, h, s).transpose(1, 2)
            w = torch.softmax(q @ k.transpose(-1, -2) / s ** 0.5 + bias, dim=-1)
            ctx = (w @ v).transpose(1, 2).reshape(self.batch, -1, d)
            x = a.output.LayerNorm(a.output.dense(ctx) + x)
            y = torch.nn.functional.gelu(layer.intermediate.dense(x))
            x = layer.output.LayerNorm(layer.output.dense(y) + x)
        return x


class Embedder(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.bert = Bert(model)

    def forward(self, input_ids, attention_mask):
        hidden = self.bert(input_ids, attention_mask, torch.zeros_like(input_ids))[:, 0]
        return torch.nn.functional.normalize(hidden, dim=-1)


class Reranker(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.bert = Bert(model.bert, batch=RERANK_BATCH)
        self.pooler, self.classifier = model.bert.pooler, model.classifier

    def forward(self, input_ids, attention_mask, token_type_ids):
        hidden = self.bert(input_ids, attention_mask, token_type_ids)
        return self.classifier(self.pooler(hidden))[:, 0]


def convert(module, names, example, output_name, shapes=None):
    traced = torch.jit.trace(module.eval(), example, strict=False)
    if shapes:
        inputs = [ct.TensorType(name=n, shape=ct.EnumeratedShapes(shapes=shapes, default=shapes[0]), dtype=np.int32) for n in names]
    else:
        length = ct.RangeDim(lower_bound=1, upper_bound=MAX_TOKENS, default=64)
        inputs = [ct.TensorType(name=n, shape=(1, length), dtype=np.int32) for n in names]
    model = ct.convert(traced, inputs=inputs, outputs=[ct.TensorType(name=output_name)],
                       convert_to="mlprogram", minimum_deployment_target=ct.target.macOS15,
                       compute_precision=ct.precision.FLOAT32)
    config = cto.coreml.OptimizationConfig(global_config=cto.coreml.OpLinearQuantizerConfig(mode="linear_symmetric", weight_threshold=2048))
    return cto.coreml.linear_quantize_weights(model, config)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default="Sources/FaciendaCore/Resources/Memory")
    args = parser.parse_args()
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    for name, revision in (("EMBEDDER_REVISION", EMBEDDER_REVISION), ("RERANKER_REVISION", RERANKER_REVISION)):
        if revision is None:
            print(f"warning: {name} is not pinned; downloading the latest upstream snapshot", file=sys.stderr)

    tokenizer = AutoTokenizer.from_pretrained(EMBEDDER, revision=EMBEDDER_REVISION)
    original = AutoModel.from_pretrained(EMBEDDER, revision=EMBEDDER_REVISION, use_safetensors=True, attn_implementation="eager").eval()
    embedder = Embedder(original)
    batch = tokenizer(SAMPLES[0][1], return_tensors="pt")
    model = convert(embedder, ["input_ids", "attention_mask"], (batch["input_ids"].int(), batch["attention_mask"].int()), "embedding")
    worst = 1.0
    for _, text in SAMPLES:
        t = tokenizer(text, return_tensors="pt")
        ref = torch.nn.functional.normalize(original(**t).last_hidden_state[:, 0], dim=-1).detach().numpy()[0]
        got = model.predict({"input_ids": t["input_ids"].int().numpy(), "attention_mask": t["attention_mask"].int().numpy()})["embedding"][0]
        worst = min(worst, float(np.dot(ref, got) / np.linalg.norm(got)))
    print(f"embedder: worst cosine to PyTorch {worst:.4f}")
    assert worst > 0.995, "quantized embedder drifted"
    shutil.rmtree(out / "MemoryEmbedder.mlpackage", ignore_errors=True)
    model.save(str(out / "MemoryEmbedder.mlpackage"))

    rtok = AutoTokenizer.from_pretrained(RERANKER, revision=RERANKER_REVISION)
    original = AutoModelForSequenceClassification.from_pretrained(RERANKER, revision=RERANKER_REVISION, use_safetensors=True, attn_implementation="eager").eval()
    reranker = Reranker(original)
    pairs = [(q, d) for q, _ in SAMPLES for d in [t for _, t in SAMPLES]][:RERANK_BATCH]
    batch = rtok([q for q, _ in pairs], [d for _, d in pairs], padding="max_length", max_length=RERANK_LENGTHS[0], truncation=True, return_tensors="pt")
    names = ["input_ids", "attention_mask", "token_type_ids"]
    model = convert(reranker, names, tuple(batch[k].int() for k in names), "score",
                    shapes=[(RERANK_BATCH, n) for n in RERANK_LENGTHS])
    worst = 0.0
    for length in RERANK_LENGTHS[:2]:
        padded = rtok([q for q, _ in pairs], [d for _, d in pairs], padding="max_length", max_length=length, truncation=True, return_tensors="pt")
        got = np.asarray(model.predict({k: padded[k].int().numpy() for k in names})["score"]).ravel()
        for i, (query, doc) in enumerate(pairs):
            ref = float(original(**rtok(query, doc, return_tensors="pt")).logits[0, 0].detach())
            worst = max(worst, abs(ref - float(got[i])))
    print(f"reranker: worst logit difference to PyTorch {worst:.3f}")
    assert worst < 0.25, "quantized reranker drifted"
    shutil.rmtree(out / "MemoryReranker.mlpackage", ignore_errors=True)
    model.save(str(out / "MemoryReranker.mlpackage"))

    assert tokenizer.vocab == rtok.vocab, "models no longer share a vocabulary"
    vocab = sorted(tokenizer.vocab.items(), key=lambda item: item[1])
    assert [i for _, i in vocab] == list(range(len(vocab)))
    (out / "vocab.txt").write_text("".join(token + "\n" for token, _ in vocab), encoding="utf-8")
    print("saved to", out)


if __name__ == "__main__":
    main()
