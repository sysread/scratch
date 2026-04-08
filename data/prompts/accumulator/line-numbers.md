# Accumulator line-numbers mode

The input has been transformed so each line is prefixed with metadata in the format:

    <line_number>:<content_hash>|<content>

The line number is 1-based and stable across the entire input (not just the current chunk).
The content hash is the first 8 hex characters of a sha256 over the line's original content.

When you reference lines in `accumulated_notes`, include both the line number and the hash.
Downstream tooling uses the hash to verify line identity even if line numbers shift between rounds (for example, when an edit pass moves content around).

You do not need to explain the format to the user; it is plumbing.
Just include the metadata when you cite specific lines.
