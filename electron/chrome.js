'use strict';
/* Shared title-bar wiring for Lumia float windows.
   - fullscreen toggle (custom, top-left) with label swap
   - close (top-right)
   - hover reporting so the main process can auto-retract / recall
   - retract handle visual state */
(function () {
  const fsBtn = document.getElementById('tbFs');
  const closeBtn = document.getElementById('tbClose');
  const titleEl = document.getElementById('tbTitle');

  if (titleEl && window.lumia) titleEl.textContent = window.lumia.title || 'Lumia';

  if (fsBtn) fsBtn.addEventListener('click', () => window.lumia.win.toggleFullscreen());
  if (closeBtn) closeBtn.addEventListener('click', () => window.lumia.win.close());

  // Reflect fullscreen state (label + rounded-corner class).
  window.lumia.win.onFullscreenChanged((isFull) => {
    document.body.classList.toggle('is-fullscreen', isFull);
    if (fsBtn) fsBtn.textContent = isFull ? '退出全屏' : '全屏';
    if (isFull) document.body.classList.remove('is-retracted');
  });

  // Hover reporting drives the 10s auto-retract + recall in the main process.
  const root = document.documentElement;
  root.addEventListener('mouseenter', () => {
    document.body.classList.remove('is-retracted');
    window.lumia.win.setHover(true);
  });
  root.addEventListener('mouseleave', () => window.lumia.win.setHover(false));

  // Let the main process tell us when it has visually retracted the window,
  // so we can show the handle sliver.
  window.lumia.win.onRetractedChanged((retracted) =>
    document.body.classList.toggle('is-retracted', retracted));

  // Kick off the retract countdown right away (a mouseenter will cancel it).
  window.lumia.win.setHover(false);
})();
