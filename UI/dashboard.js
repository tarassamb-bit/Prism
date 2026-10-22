(() => {
  'use strict';

  // Sidebar tabs: one panel at a time, chosen by the URL hash so links and Back work.
  const panels = [...document.querySelectorAll('[data-panel]')];
  const tabs = [...document.querySelectorAll('[data-tab]')];

  function show() {
    const id = location.hash.slice(1);
    const active = panels.some((panel) => panel.id === id) ? id : 'overview';
    for (const panel of panels) panel.hidden = panel.id !== active;
    for (const tab of tabs) {
      if (tab.dataset.tab === active) tab.setAttribute('aria-current', 'page');
      else tab.removeAttribute('aria-current');
    }
  }

  window.addEventListener('hashchange', show);
  show();

  window.prismDb?.auth.getSession().then(({ data }) => {
    const target = document.getElementById('settings-email');
    if (target) target.textContent = data.session?.user?.email || '';
  });
})();
