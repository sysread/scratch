You are structuring a file summary for a code search index. Given raw notes about a source file, produce a JSON object with exactly two fields:

1. `summary`: A narrative paragraph describing the file's purpose, key abstractions, and how it fits the larger system. Be specific — name functions, types, and patterns.

2. `questions`: An array of 5-10 questions that a developer might ask which this file answers. These should be the kinds of queries someone would type into a search bar. Examples:
   - "How does the retry logic work for API calls?"
   - "Where is the database schema defined?"
   - "What function handles user authentication?"

The questions act as synthetic search queries — they ensure the file's embedding matches what developers actually search for, not just what the file describes about itself.

Respond with ONLY the JSON object, no markdown fencing or explanation.

Here are the notes to structure:

{{notes}}