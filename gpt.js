import { getSettings } from './settings.js';

const EMBED_MODEL = 'text-embedding-3-small';
const EMBED_ENDPOINT = 'https://api.openai.com/v1/embeddings';

const QUERY_MODEL = 'gpt-4o';
const QUERY_ENDPOINT = 'https://api.openai.com/v1/chat/completions';
const QUERY_SYSTEM_PROMPT = `
You are an assistant that helps manage a list of facts stored in a database.
Each fact has a unique numerical ID.
The facts can be created, updated, deleted, or searched based on the user's input.
One of your jobs is to reformat the user's queries and the wording of facts to ensure consistency and effectiveness.

Here are the guidelines for how you should respond:

1. If the user wants to create or remember a new fact, respond with "CREATE | [fact]"
2. If the user wants to update an existing fact, respond with "UPDATE | [id] | [new fact]"
3. If the user wants to delete a fact, respond with "DELETE | [id]"
4. If the user wants to search for a fact, respond with "SEARCH | [query]"
5. If, for whatever reason, you need to retrieve all entries at once, respond with "SEARCH | all"

When search results are provided by the app, they will be in the format "INFO | [id] | [fact]".
Use these IDs for subsequent update or delete operations as requested by the user.
Assimilate the search results and respond to the user's question in a natural and informative manner.

Examples:
User input: "Add a new fact that the sky is blue."
Response: "CREATE | The sky is blue."

User input: "Change the fact with ID 2 to say that the sky is sometimes grey."
Response: "UPDATE | 2 | The sky is sometimes grey."

User input: "Remove the fact with ID 3."
Response: "DELETE | 3"

User input: "Find facts about the weather."
Response: "SEARCH | weather"

User input: "Summarize everything you remember about me."
Response: "SEARCH | all"

User input: "INFO | 1 | The sky is mostly blue.\nINFO | 2 | The sky is grey when it rains."
Response: "ANSWER | The sky is typically blue. On rainy days, it may be grey."

Be certain that each directive is restricted to a single line of input and newlines are escaped.
You may include multiple directives per message if necessary.

If the user asks to update or delete a fact, determine the relevant ID from the search results and respond with the appropriate action.

If the user asks you to update or delete a fact you do not know the ID of, first search for the fact and then proceed with the update or delete operation.

ONLY use CREATE, UPDATE, and DELETE if the user EXPLICITLY asks you to remember, change, or remove a fact.

ALWAYS try to answer the user's question using SEARCH results before resorting to a direct response using your training data.
`;

const QUERY_SPLIT_RE = /(?=^CREATE \| |^UPDATE \| |^DELETE \| |^SEARCH \| |^ANSWER \| )/gm;

function splitWithLimit(str, delimiter, limit) {
  if (limit <= 0) {
    return [str];
  }

  const parts = str.split(delimiter);
  const result = parts.slice(0, limit);

  if (parts.length > limit) {
    result.push(parts.slice(limit).join(delimiter));
  }

  return result;
}

export async function getEmbedding(text) {
  const apiKey = getSettings().openaiApiKey;

  const headers = {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${apiKey}`,
  };

  const payload = {
    input: text,
    model: EMBED_MODEL,
    encoding_format: 'float',
  };

  const response = await fetch(EMBED_ENDPOINT, {
    method: 'POST',
    headers: headers,
    body: JSON.stringify(payload),
  });

  const data = await response.json();

  return data.data[0].embedding;
}

/*
 * Message format for `conversation` is the same as what is returned by the API:
 *   [
 *      { role: 'system', content: QUERY_SYSTEM_PROMPT },
 *      { role: 'user', content: 'Add a new fact that the sky is blue.' },
 *      { role: 'system', content: 'CREATE | The sky is blue.'
 *      { role: 'user', content: 'What color is the sky?' },
 *      { role: 'system', content: 'SEARCH | sky color' },
 *      { role: 'user', content: 'INFO | 1 | The sky is blue.' },
 *      { role: 'system', content: 'The sky is the color blue.' },
 *   ]
 */
export async function getResponse(text, role, conversation = []) {
  if (conversation.length == 0 || conversation[0].content !== QUERY_SYSTEM_PROMPT) {
    conversation.unshift({ role: 'system', content: QUERY_SYSTEM_PROMPT });
  }

  conversation.push({ role: role, content: text });

  console.log('THREAD', conversation);
  console.log('SEND', text);

  const apiKey = getSettings().openaiApiKey;

  const headers = {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${apiKey}`,
  };

  const payload = {
    model: QUERY_MODEL,
    stream: false,
    messages: conversation,
  };

  const response = await fetch(QUERY_ENDPOINT, {
    method: 'POST',
    headers: headers,
    body: JSON.stringify(payload),
  });

  const data = await response.json();
  const message = data.choices[0].message.content;

  console.log('RECV', message);

  const directives = message
    .split(QUERY_SPLIT_RE)
    .map((directive) => directive.trim())
    .filter((directive) => directive !== null)
    .map((directive) => {
      const [action, ...rest] = directive.split(' | ');

      switch (action) {
        case 'CREATE': {
          return { action: action, body: rest[0] };
          break;
        }

        case 'UPDATE': {
          const [id, body] = rest;
          return { action: action, id: id, body: body };
          break;
        }

        case 'DELETE': {
          return { action: action, id: rest[0] };
          break;
        }

        case 'SEARCH': {
          return { action: action, query: rest[0] };
          break;
        }

        case 'ANSWER': {
          return { action: action, body: rest[0] };
          break;
        }

        default: {
          return { action: 'MESSAGE', body: directive };
          break;
        }
      }
    });

  return {
    message: message,
    directives: directives,
  };
}
