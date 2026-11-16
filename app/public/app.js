const list = document.querySelector('[data-testid="item-list"]');
const form = document.querySelector('[data-testid="add-item-form"]');
const input = document.querySelector('[data-testid="new-item-input"]');

async function loadEnvironment() {
  const env = await (await fetch('/api/environment')).json();
  document.querySelector('[data-testid="env-name"]').textContent = env.envName;
  document.querySelector('[data-testid="env-pr"]').textContent = env.prNumber || 'none';
  document.querySelector('[data-testid="env-commit"]').textContent = env.commitSha || 'unknown';
}

function renderItem(item) {
  const li = document.createElement('li');
  li.dataset.testid = `item-${item.id}`;
  li.className = item.done ? 'done' : '';

  const checkbox = document.createElement('input');
  checkbox.type = 'checkbox';
  checkbox.checked = item.done;
  checkbox.dataset.testid = `item-toggle-${item.id}`;
  checkbox.setAttribute('aria-label', `Mark "${item.title}" done`);
  checkbox.addEventListener('change', () => toggleItem(item.id));

  const label = document.createElement('span');
  label.textContent = item.title;
  label.dataset.testid = `item-title-${item.id}`;

  li.append(checkbox, label);
  return li;
}

async function loadItems() {
  const items = await (await fetch('/api/items')).json();
  list.replaceChildren(...items.map(renderItem));
}

async function toggleItem(id) {
  await fetch(`/api/items/${id}`, { method: 'PATCH' });
  await loadItems();
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const title = input.value.trim();
  if (!title) return;
  await fetch('/api/items', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ title }),
  });
  input.value = '';
  await loadItems();
});

loadEnvironment();
loadItems();
