#!/usr/bin/env awk -f

# Line-oriented cosine similarity ranking.
#
# Needle embedding passed via -v needle="[1.0,2.0,...]" so it's parsed
# once at startup. Each input line is tab-delimited: identifier<TAB>embedding.
# Emits score<TAB>identifier immediately per line (streaming), then sorts
# at the end for top_k.
#
# Usage:
#   db:query ... | awk -v needle="$query_json" -v top_k=10 -f cosine-rank-v2.awk

BEGIN {
  FS = "\t"
  if (top_k == "") top_k = 10
  ndim = parse_json_array(needle, q)
  result_count = 0
}

{
  dim = parse_json_array($2, hay)
  if (dim != ndim) next

  dot = 0; norm_a = 0; norm_b = 0
  for (i = 1; i <= dim; i++) {
    dot    += q[i] * hay[i]
    norm_a += q[i] * q[i]
    norm_b += hay[i] * hay[i]
  }
  denom = sqrt(norm_a) * sqrt(norm_b)
  score = (denom > 0) ? dot / denom : 0

  result_count++
  result_scores[result_count] = score
  result_ids[result_count] = $1
}

END {
  # Insertion sort descending
  for (i = 2; i <= result_count; i++) {
    s = result_scores[i]
    id = result_ids[i]
    j = i - 1
    while (j >= 1 && result_scores[j] < s) {
      result_scores[j + 1] = result_scores[j]
      result_ids[j + 1] = result_ids[j]
      j--
    }
    result_scores[j + 1] = s
    result_ids[j + 1] = id
  }

  limit = (result_count < top_k) ? result_count : top_k
  for (i = 1; i <= limit; i++) {
    printf "%.3f\t%s\n", result_scores[i], result_ids[i]
  }
}

function parse_json_array(s, arr,    clean, tmp, count, i) {
  clean = s
  gsub(/[\[\]\r\n]/, "", clean)
  count = split(clean, tmp, ",")
  for (i = 1; i <= count; i++)
    arr[i] = tmp[i] + 0
  return count
}
