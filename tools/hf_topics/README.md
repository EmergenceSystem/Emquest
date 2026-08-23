# em-hf-topics

Local HuggingFace topic-extraction microservice for Emergence/Emquest.

`queen:expand/1` (Emquest) calls this to turn a multi-word query into
semantic topic words, then fans out one sub-query per topic. Falls back to
`queen:local_keywords/1` (stopword split) if this service is unavailable.

- **Endpoint:** `POST http://127.0.0.1:8085/topics` — `{"query":"...", "top_n":5}` → `{"topics":[...]}`
- **Health:** `GET /health`
- **Model:** KeyBERT + sentence-transformers `paraphrase-multilingual-MiniLM-L12-v2` (FR/EN), 1-gram topics.

## Deploy (Ubuntu ARM)

```bash
python3 -m venv ~/hfenv
~/hfenv/bin/pip install -r requirements.txt
cp hf_topics.py ~/hf_topics.py
sudo cp emergence-hf-topics.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now emergence-hf-topics
```

First start downloads the model (~30-60s to become healthy).
