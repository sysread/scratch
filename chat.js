import { getEmbedding, getResponse } from './gpt.js';
import { getSettings } from './settings.js';
import Storage from './storage.js';

const conversation = [];

function buildMessageCard(role, content) {
  const card = document.createElement('div');
  card.classList.add('card');
  card.classList.add('mb-2');

  const header = document.createElement('h6');
  header.classList.add('card-subtitle');
  header.classList.add('m-2');
  header.classList.add('text-body-secondary');

  switch (role) {
    case 'user':
      header.textContent = 'You';
      break;

    case 'assistant':
      header.textContent = 'Assistant';
      break;

    case 'system':
      header.textContent = 'System';
      break;

    default:
      console.log(`Unknown role: ${role}`);
      break;
  }

  const body = document.createElement('div');
  body.classList.add('card-body');

  const text = document.createElement('div');
  text.classList.add('chat-message');
  text.classList.add('chat-message-assistant');
  text.innerHTML = marked.marked(content);

  body.appendChild(text);
  card.appendChild(header);
  card.appendChild(body);

  return card;
}

function addMessage(role, text) {
  const messagePane = document.getElementById('chat-messages');
  const card = buildMessageCard(role, text);
  messagePane.appendChild(card);

  // Auto-scroll to the bottom
  messagePane.scrollTop = messagePane.scrollHeight;
}

async function sendMessage(role, text) {
  const userInput = document.getElementById('chat-user-input');
  const sendButton = document.getElementById('chat-submit');

  if (text === '') {
    return false;
  }

  if (role == 'user') {
    addMessage('user', text);
  }

  // Retrieve the response
  const { message, directives } = await getResponse(text, role, conversation);
  conversation.push({ role: 'assistant', content: message });

  // The input is disabled; leave it disabled, but clear the text now that
  // the message has been sent.
  userInput.value = '';

  for (let i = 0; i < directives.length; ++i) {
    const directive = directives[i];
    console.log('DIRECTIVE', directive);

    switch (directive.action) {
      case 'CREATE': {
        const entry = await Storage.add(directive.body);
        const msg = `Entry created with ID ${entry.id}: ${directive.body}`;
        conversation.push({ role: 'system', content: msg });
        addMessage('system', msg);
        break;
      }

      case 'UPDATE': {
        await Storage.update(directive.id, directive.body);
        const msg = `Entry updated with ID ${directive.id}: ${directive.body}`;
        conversation.push({ role: 'system', content: msg });
        addMessage('system', msg);
        break;
      }

      case 'DELETE': {
        await Storage.drop(directive.id);
        const msg = `Entry deleted with ID ${directive.id}`;
        conversation.push({ role: 'system', content: msg });
        addMessage('system', msg);
        break;
      }

      case 'SEARCH': {
        const entries = await Storage.search(directive.query, 10);
        const response = entries.map((entry) => `INFO | ${entry.id} | ${entry.body}`).join('\n');
        conversation.push({ role: 'system', content: response });
        await sendMessage('system', response);
        break;
      }

      case 'ANSWER': {
        addMessage('assistant', directive.body);
        break;
      }

      default: {
        addMessage('assistant', directive.body);
        break;
      }
    }
  }

  // Re-enable the input field and focus it
  userInput.disabled = false;
  userInput.focus();
}

document.addEventListener('DOMContentLoaded', () => {
  const userInput = document.getElementById('chat-user-input');
  const sendButton = document.getElementById('chat-submit');

  // Automatically resize the textarea based on its content
  userInput.addEventListener('input', () => {
    userInput.style.height = 'auto';
    userInput.style.height = userInput.scrollHeight + 'px';

    // Ensure the height does not exceed the max height
    const maxHeight = parseInt(window.getComputedStyle(userInput).maxHeight);
    if (userInput.scrollHeight > maxHeight) {
      userInput.style.overflowY = 'scroll';
    } else {
      userInput.style.overflowY = 'hidden';
    }
  });

  // Handle form submission
  sendButton.addEventListener('click', async () => {
    const apiKey = getSettings().openaiApiKey;
    console.log(apiKey);
    if (apiKey === '') {
      addMessage('system', 'Please configure your OpenAI API key in settings.');
      return;
    }

    userInput.disabled = true;
    const text = userInput.value;
    sendMessage('user', text);
  });

  // On load, immediately focus the user input field
  userInput.focus();

  document.getElementById('debug').addEventListener('click', async () => {
    console.log('STORAGE', await Storage.debug());
  });
});
