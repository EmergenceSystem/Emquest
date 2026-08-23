"""HF topic extraction microservice for Emergence/Emquest.

POST /topics {"query": "...", "top_n": 5} -> {"topics": ["word", ...]}
Extracts the most semantically salient single-word topics from a query
using KeyBERT over a multilingual MiniLM sentence embedding (FR/EN).
"""
from fastapi import FastAPI
from pydantic import BaseModel
from keybert import KeyBERT
from sentence_transformers import SentenceTransformer

MODEL_NAME = "paraphrase-multilingual-MiniLM-L12-v2"
_model = SentenceTransformer(MODEL_NAME)
_kw = KeyBERT(model=_model)

app = FastAPI(title="emergence-hf-topics")


class Q(BaseModel):
    query: str
    top_n: int = 5


@app.get("/health")
def health():
    return {"ok": True, "model": MODEL_NAME}


@app.post("/topics")
def topics(q: Q):
    text = (q.query or "").strip()
    if not text:
        return {"topics": []}
    # single-word queries: nothing to extract
    if len(text.split()) < 2:
        return {"topics": [text]}
    pairs = _kw.extract_keywords(
        text,
        keyphrase_ngram_range=(1, 1),
        stop_words=None,
        top_n=max(1, min(q.top_n, 8)),
    )
    seen, out = set(), []
    for phrase, _score in pairs:
        w = phrase.lower().strip()
        if len(w) >= 3 and w not in seen:
            seen.add(w)
            out.append(w)
    return {"topics": out}
