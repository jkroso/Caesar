(() => {
  const INTERACTIVE_TAGS = new Set([
    'A', 'BUTTON', 'INPUT', 'SELECT', 'TEXTAREA', 'DETAILS', 'SUMMARY'
  ]);
  const INTERACTIVE_ROLES = new Set([
    'button', 'link', 'tab', 'menuitem', 'checkbox', 'radio',
    'switch', 'option', 'combobox', 'textbox', 'searchbox',
    'slider', 'spinbutton', 'menuitemcheckbox', 'menuitemradio'
  ]);
  const SKIP_TAGS = new Set([
    'SCRIPT', 'STYLE', 'NOSCRIPT', 'SVG', 'PATH', 'META', 'LINK', 'BR', 'HR'
  ]);

  function isVisible(el) {
    if (el.offsetParent === null && el.tagName !== 'BODY' && el.tagName !== 'HTML'
        && getComputedStyle(el).position !== 'fixed') return false;
    const s = getComputedStyle(el);
    if (s.display === 'none' || s.visibility === 'hidden' || parseFloat(s.opacity) === 0) return false;
    const r = el.getBoundingClientRect();
    if (r.width === 0 && r.height === 0) return false;
    return true;
  }

  function isInteractive(el) {
    if (INTERACTIVE_TAGS.has(el.tagName)) return true;
    const role = el.getAttribute('role');
    if (role && INTERACTIVE_ROLES.has(role)) return true;
    if (el.hasAttribute('onclick') || el.hasAttribute('tabindex')) return true;
    if (el.contentEditable === 'true') return true;
    return false;
  }

  function truncate(s, n) {
    s = s.replace(/\s+/g, ' ').trim();
    return s.length > n ? s.slice(0, n) + '...' : s;
  }

  function inputDesc(el) {
    const type = el.getAttribute('type') || 'text';
    const name = el.getAttribute('name') || '';
    const ph = el.getAttribute('placeholder') || '';
    const val = el.value || '';
    const checked = el.checked;
    let desc = `input[${type}]`;
    if (name) desc += ` name="${name}"`;
    if (ph) desc += ` placeholder="${truncate(ph, 30)}"`;
    if (type === 'checkbox' || type === 'radio') desc += checked ? ' [checked]' : ' [unchecked]';
    else if (val) desc += ` value="${truncate(val, 30)}"`;
    return desc;
  }

  function selectDesc(el) {
    const name = el.getAttribute('name') || '';
    const selected = el.options[el.selectedIndex];
    let desc = 'select';
    if (name) desc += ` name="${name}"`;
    if (selected) desc += ` selected="${truncate(selected.text, 30)}"`;
    return desc;
  }

  const elements = [];
  let index = 0;
  const lines = [];

  function walk(node, depth) {
    if (node.nodeType !== 1) return; // Element nodes only
    if (SKIP_TAGS.has(node.tagName)) return;
    if (!isVisible(node)) return;

    const interactive = isInteractive(node);
    let line = null;

    if (interactive) {
      const tag = node.tagName.toLowerCase();
      const idx = index++;
      elements.push(node);

      let desc;
      if (tag === 'input') {
        desc = inputDesc(node);
      } else if (tag === 'select') {
        desc = selectDesc(node);
      } else if (tag === 'textarea') {
        const name = node.getAttribute('name') || '';
        const val = node.value || '';
        desc = 'textarea';
        if (name) desc += ` name="${name}"`;
        if (val) desc += ` value="${truncate(val, 40)}"`;
      } else {
        const text = truncate(node.innerText || '', 60);
        const href = node.getAttribute('href');
        desc = tag;
        if (text) desc += ` "${text}"`;
        if (href && href !== '#' && !href.startsWith('javascript:'))
          desc += ` -> ${truncate(href, 60)}`;
      }

      const role = node.getAttribute('role');
      if (role) desc += ` role=${role}`;
      const ariaLabel = node.getAttribute('aria-label');
      if (ariaLabel) desc += ` aria="${truncate(ariaLabel, 30)}"`;

      line = `${'  '.repeat(depth)}[${idx}] ${desc}`;
    }

    if (line) lines.push(line);

    for (const child of node.children) {
      walk(child, interactive ? depth + 1 : depth);
    }
  }

  walk(document.body, 0);
  window.__prosca_elements = elements;

  const header = `url: ${location.href}\ntitle: ${document.title}\nscroll: ${window.scrollY}/${document.documentElement.scrollHeight}\nelements: ${elements.length}`;
  return header + '\n---\n' + lines.join('\n');
})()
