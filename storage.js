import Dexie from 'https://cdn.jsdelivr.net/npm/dexie@latest/dist/dexie.mjs';
import cosineSimilarity from 'https://cdn.jsdelivr.net/npm/compute-cosine-similarity@1.1.0/+esm';
import { getEmbedding } from './ai.js';

// Initialize Dexie
const db = new Dexie('scratchdb');

db.version(1).stores({
  entries: '++id,body,embedding,created_at,modified_at',
});

const Storage = {
  forceIntId(id) {
    if (typeof id === 'string') {
      return parseInt(id, 10);
    } else {
      return id;
    }
  },

  // Retrieve an entry by id
  async get(id) {
    id = this.forceIntId(id);
    console.log('storage.get', id);
    const entry = await db.entries.get(id);

    if (entry) {
      entry.embedding = JSON.parse(entry.embedding);
    }

    return entry;
  },

  // Create a new entry
  async add(body) {
    console.log('storage.add', body);
    const embedding = await getEmbedding(body);
    const now = new Date().toISOString();

    const entry = {
      body: body,
      embedding: JSON.stringify(embedding),
      created_at: now,
      modified_at: now,
    };

    const id = await db.entries.add(entry);
    console.log('storage.add', id, entry);
    return { id, ...entry };
  },

  // Update an entry by id
  async update(id, body) {
    id = this.forceIntId(id);
    console.log('storage.update', id, body);
    const embedding = await getEmbedding(body);
    const now = new Date().toISOString();

    const updates = {
      body: body,
      embedding: JSON.stringify(embedding),
      modified_at: now,
    };

    await db.entries.update(id, updates);
    return this.get(id);
  },

  // Delete an entry by id
  async drop(id) {
    id = this.forceIntId(id);
    console.log('storage.drop', id);
    return await db.entries.delete(id);
  },

  // Search entries by embedding similarity
  async search(input, top_n) {
    console.log('storage.search', input, top_n);

    if (input === 'all') {
      return await this.all();
    }

    const inputEmbedding = await getEmbedding(input);
    const allEntries = await db.entries.toArray();

    const similarities = allEntries.map((entry) => {
      const embedding = JSON.parse(entry.embedding);
      const distance = cosineSimilarity(inputEmbedding, embedding);
      return { entry, distance };
    });

    similarities.sort((a, b) => b.distance - a.distance);

    return similarities.slice(0, top_n).map((result) => result.entry);
  },

  async all() {
    console.log('storage.all');
    return await db.entries.toArray();
  },

  async debug() {
    console.log('storage.debug');
    window.db = db;
    return await db.entries.toArray();
  },
};

export default Storage;
