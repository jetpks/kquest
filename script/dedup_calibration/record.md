# dedup-constants recalibration run record

floor = 0.8387
k = 2
dataset_sha256 = cbc94f8b853bf93dc922aaabc5f0bd326982865649d2d95f0975674325e9d641
pairs = 42
model = bge-m3 92000000-0000-4000-8000-000000000001
date = 2026-11-24T11:34:10Z

Decision rule (verbatim): floor = the threshold minimizing misclassifications over the
observed cosines (a paraphrase pair below floor and a distinct pair above floor are
errors; ties in error count → the candidate closest to the provisional 0.6), CLAMPED to
[0.30, 0.95]. k = the largest observed count of dataset texts at or above the chosen
floor around any single probe text (the real surfacing budget), clamped to [1, 50].
Chosen raw threshold 0.8387 carried 0 misclassification(s) of 42 pairs.

Families overlap in observed cosine: NO

Per-family cosine distributions:
- cross_topic_distinct: count=14 min=0.2834 median=0.4092 max=0.6071
- paraphrase: count=14 min=0.8387 median=0.9256 max=0.9737
- same_topic_distinct: count=14 min=0.5205 median=0.7028 max=0.7995

Every pair's cosine:
| id | family | cosine |
|----|--------|--------|
| p01 | paraphrase | 0.9256 |
| p02 | paraphrase | 0.9202 |
| p03 | paraphrase | 0.89 |
| p04 | paraphrase | 0.9737 |
| p05 | paraphrase | 0.9007 |
| p06 | paraphrase | 0.8387 |
| p07 | paraphrase | 0.9476 |
| p08 | paraphrase | 0.9191 |
| p09 | paraphrase | 0.934 |
| p10 | paraphrase | 0.9673 |
| p11 | paraphrase | 0.9475 |
| p12 | paraphrase | 0.9146 |
| p13 | paraphrase | 0.9683 |
| p14 | paraphrase | 0.9117 |
| s01 | same_topic_distinct | 0.7995 |
| s02 | same_topic_distinct | 0.776 |
| s03 | same_topic_distinct | 0.6994 |
| s04 | same_topic_distinct | 0.7397 |
| s05 | same_topic_distinct | 0.6411 |
| s06 | same_topic_distinct | 0.7102 |
| s07 | same_topic_distinct | 0.6092 |
| s08 | same_topic_distinct | 0.7421 |
| s09 | same_topic_distinct | 0.5969 |
| s10 | same_topic_distinct | 0.7028 |
| s11 | same_topic_distinct | 0.7846 |
| s12 | same_topic_distinct | 0.5205 |
| s13 | same_topic_distinct | 0.6524 |
| s14 | same_topic_distinct | 0.6232 |
| c01 | cross_topic_distinct | 0.3835 |
| c02 | cross_topic_distinct | 0.4213 |
| c03 | cross_topic_distinct | 0.352 |
| c04 | cross_topic_distinct | 0.518 |
| c05 | cross_topic_distinct | 0.4945 |
| c06 | cross_topic_distinct | 0.3469 |
| c07 | cross_topic_distinct | 0.6071 |
| c08 | cross_topic_distinct | 0.2834 |
| c09 | cross_topic_distinct | 0.3672 |
| c10 | cross_topic_distinct | 0.5458 |
| c11 | cross_topic_distinct | 0.5046 |
| c12 | cross_topic_distinct | 0.2864 |
| c13 | cross_topic_distinct | 0.4092 |
| c14 | cross_topic_distinct | 0.3655 |

Usage echo (the run's whole spend record — no usage_events row: a calibration run has
no session→phase→quest→user chain; the D10 chain starts at session):
prompt_tokens=1350 total_tokens=1350
Cost arithmetic: OpenRouter bge-m3 embedding spend ≈ $0.000014 at $1e-5/1k tokens.

Re-verification command (the judge's live duty — with the key):
  HANAMI_ENV=test bundle exec ruby script/dedup_recalibration.rb
Keyless shape (the loud-skip law):
  KQUEST_RECAL_KEY_PATH=/nonexistent HANAMI_ENV=test bundle exec ruby script/dedup_recalibration.rb
