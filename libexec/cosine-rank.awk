#!/usr/bin/env awk -f

#-------------------------------------------------------------------------------
# Cosine similarity ranking
#
# Reads a query embedding and a set of candidate entries, computes cosine
# similarity between the query and each candidate, and outputs the top K
# results sorted by descending score.
#
# Input format:
#   - First line: the query embedding as a JSON array of floats
#   - Remaining lines: tab-delimited <identifier>\t<embedding JSON array>
#
# Output format:
#   Tab-delimited lines: <score>\t<identifier>
#   Score is rounded to 3 decimal places. Sorted descending by score.
#   Only the top K results are printed (K from -v top_k=N, default 10).
#
# Usage:
#   { echo "$query_json"; db:query "$db" "SELECT ..."; } \
#     | awk -v top_k=10 -f libexec/cosine-rank.awk
#-------------------------------------------------------------------------------

BEGIN {
  FS = "\t"
  if (top_k == "") top_k = 10
  result_count = 0
}

# First line is the query embedding
NR == 1 {
  query_dim = parse_json_array($0, query)
  next
}

# Remaining lines: identifier<tab>embedding
{
  identifier = $1
  dim = parse_json_array($2, candidate)

  if (dim != query_dim) next

  score = cosine_similarity(query, candidate, dim)

  result_count++
  result_scores[result_count] = score
  result_ids[result_count] = identifier
}

END {
  # Insertion sort by descending score (fine for expected result sizes)
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

# Parse a JSON array of floats into arr[1..N], return the count.
function parse_json_array(s, arr,    clean, tmp, count, i) {
  clean = s
  gsub(/[\[\]\r\n]/, "", clean)
  count = split(clean, tmp, ",")
  for (i = 1; i <= count; i++)
    arr[i] = tmp[i] + 0
  return count
}

# Cosine similarity between two vectors of length n.
function cosine_similarity(a, b, n,    dot, norm_a, norm_b, denom, i) {
  dot = 0; norm_a = 0; norm_b = 0
  for (i = 1; i <= n; i++) {
    dot    += a[i] * b[i]
    norm_a += a[i] * a[i]
    norm_b += b[i] * b[i]
  }
  denom = sqrt(norm_a) * sqrt(norm_b)
  return (denom > 0) ? dot / denom : 0
}
