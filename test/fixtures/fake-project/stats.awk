#!/usr/bin/env awk -f
# Reads numbers from stdin (one per line) and prints basic statistics:
# count, sum, mean, min, max.

BEGIN {
  count = 0
  sum = 0
  min = ""
  max = ""
}

{
  val = $1 + 0
  count++
  sum += val
  if (min == "" || val < min) min = val
  if (max == "" || val > max) max = val
}

END {
  if (count > 0) {
    printf "count: %d\n", count
    printf "sum:   %.2f\n", sum
    printf "mean:  %.2f\n", sum / count
    printf "min:   %.2f\n", min
    printf "max:   %.2f\n", max
  } else {
    print "no data"
  }
}
