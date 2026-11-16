const express = require('express');
const path = require('path');

const PORT = 8080;

const app = express();
app.use(express.json());

// Environment details shown in the page banner, so a viewer can see which
// environment served the page.
const environment = {
  envName: process.env.ENV_NAME || 'local',
  prNumber: process.env.PR_NUMBER || '',
  commitSha: (process.env.COMMIT_SHA || '').slice(0, 7),
};

// In-memory storage. Each pod starts with the same seed items.
let nextId = 1;
const items = [];
function addItem(title, done = false) {
  const item = { id: nextId++, title, done };
  items.push(item);
  return item;
}
addItem('Review release notes', true);
addItem('Run end-to-end tests');
addItem('Approve production deployment');

app.get('/healthz', (req, res) => {
  res.json({ status: 'ok' });
});

app.get('/api/environment', (req, res) => {
  res.json(environment);
});

app.get('/api/items', (req, res) => {
  res.json(items);
});

app.post('/api/items', (req, res) => {
  const title = typeof req.body.title === 'string' ? req.body.title.trim() : '';
  if (!title) {
    return res.status(400).json({ error: 'title is required' });
  }
  res.status(201).json(addItem(title));
});

app.patch('/api/items/:id', (req, res) => {
  const item = items.find((i) => i.id === Number(req.params.id));
  if (!item) {
    return res.status(404).json({ error: 'item not found' });
  }
  item.done = !item.done;
  res.json(item);
});

app.use(express.static(path.join(__dirname, 'public')));

app.listen(PORT, () => {
  console.log(`Release checklist listening on port ${PORT} (environment: ${environment.envName})`);
});
