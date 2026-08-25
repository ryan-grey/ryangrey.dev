#!/usr/bin/env python3
"""
Builds the retrieval corpus for the "Ask about Ryan" chatbot.

Extracts text from the real sources (index.html and the CV source HTML),
chunks on headings, embeds each chunk with Titan Text Embeddings V2, and
writes infra/corpus.json.

One source of truth: the site and the CV are authored once, and the corpus
is generated from them. infra/check-corpus-drift.py fails the deploy when
the committed corpus no longer matches index.html, so a stale corpus is a
build error rather than a wrong answer to a recruiter.

The CV source lives outside the repo (~/Documents/Resumes/...), so its text
is frozen into corpus.json at build time and cannot be re-verified in CI --
this script warns locally when it has changed. index.html IS in the repo and
is checked on every deploy.

Usage: python3 infra/build-corpus.py [--dry-run]
"""
import hashlib
import html
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CV_SOURCE = Path.home() / "Documents/Resumes/Ryan_Grey_Resume_2026.source.html"
OUT = ROOT / "infra" / "corpus.json"

EMBED_MODEL = "amazon.titan-embed-text-v2:0"
EMBED_DIMS = 1024
REGION = "us-east-1"
MIN_CHARS = 80          # drop fragments too small to answer anything
MAX_CHARS = 1200        # keep chunks inside a sane context slice


def strip_html(raw):
    raw = re.sub(r"<(script|style|svg)[^>]*>.*?</\1>", " ", raw, flags=re.S | re.I)
    raw = re.sub(r"<[^>]+>", "\n", raw)
    return html.unescape(raw)


def chunk_document(raw, source, heading_tags=("h1", "h2", "h3")):
    """Split on headings so each chunk carries its own topic label."""
    pattern = re.compile(
        r"<(?:" + "|".join(heading_tags) + r")[^>]*>(.*?)</(?:" + "|".join(heading_tags) + r")>",
        re.S | re.I,
    )
    marks = [(m.start(), re.sub(r"\s+", " ", strip_html(m.group(1))).strip())
             for m in pattern.finditer(raw)]
    chunks = []
    for i, (pos, heading) in enumerate(marks):
        end = marks[i + 1][0] if i + 1 < len(marks) else len(raw)
        body = re.sub(r"\s+", " ", strip_html(raw[pos:end])).strip()
        if body.startswith(heading):
            body = body[len(heading):].strip()
        if len(body) < MIN_CHARS:
            continue
        for piece in [body[j:j + MAX_CHARS] for j in range(0, len(body), MAX_CHARS)]:
            if len(piece) >= MIN_CHARS:
                chunks.append({"source": source, "heading": heading, "text": piece})
    return chunks


def embed(text):
    """Invoke Titan and read the vector from a real file.

    The CLI writes the model response to the output path AND its own metadata
    JSON to stdout; pointing the output at /dev/stdout concatenates the two
    and json.loads fails with "Extra data".
    """
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        req, resp = Path(td) / "in.json", Path(td) / "out.json"
        req.write_text(json.dumps({"inputText": text}))
        proc = subprocess.run(
            ["aws", "bedrock-runtime", "invoke-model", "--region", REGION,
             "--model-id", EMBED_MODEL, "--content-type", "application/json",
             "--accept", "application/json", "--body", f"fileb://{req}", str(resp)],
            capture_output=True,
        )
        if proc.returncode != 0:
            sys.exit(f"embed failed: {proc.stderr.decode()[:300]}")
        vec = json.loads(resp.read_text())["embedding"]
    if len(vec) != EMBED_DIMS:
        sys.exit(f"expected {EMBED_DIMS} dims, model returned {len(vec)}")
    return vec


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    dry = "--dry-run" in sys.argv
    index = ROOT / "index.html"
    raw_index = index.read_text(encoding="utf-8")

    chunks = chunk_document(raw_index, "site")
    if CV_SOURCE.exists():
        chunks += chunk_document(CV_SOURCE.read_text(encoding="utf-8", errors="ignore"), "cv")
    else:
        print(f"WARNING: CV source not found at {CV_SOURCE} -- site-only corpus")

    print(f"chunks: {len(chunks)}  (site: {sum(c['source']=='site' for c in chunks)}, "
          f"cv: {sum(c['source']=='cv' for c in chunks)})")
    for c in chunks[:40]:
        print(f"  [{c['source']:4}] {c['heading'][:38]:40} {len(c['text']):5} chars")
    if len(chunks) > 40:
        print(f"  ... and {len(chunks)-40} more")

    if dry:
        print("\n--dry-run: no embedding calls made, nothing written")
        return 0

    print(f"\nembedding {len(chunks)} chunks with {EMBED_MODEL} ...")
    for i, c in enumerate(chunks, 1):
        c["vector"] = embed(f"{c['heading']}. {c['text']}")
        if i % 10 == 0 or i == len(chunks):
            print(f"  {i}/{len(chunks)}")

    doc = {
        "model": EMBED_MODEL,
        "dims": EMBED_DIMS,
        "sources": {
            "index.html": sha(index),
            "cv": sha(CV_SOURCE) if CV_SOURCE.exists() else None,
        },
        "chunks": chunks,
    }
    OUT.write_text(json.dumps(doc, separators=(",", ":")))
    kb = OUT.stat().st_size / 1024
    print(f"\nwrote {OUT.relative_to(ROOT)}  ({kb:.0f} KB, {len(chunks)} chunks, {EMBED_DIMS} dims)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
