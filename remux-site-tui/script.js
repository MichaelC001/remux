(() => {
  "use strict";

  const sectionIDs = ["home", "sessions", "windows", "terminal", "get"];
  const sections = sectionIDs
    .map((id) => document.getElementById(id))
    .filter((section) => section !== null);
  const windowLinks = Array.from(document.querySelectorAll("[data-window]"));
  const mobileWindow = document.getElementById("mobile-window");
  const clock = document.getElementById("clock");
  const terminalTabs = Array.from(document.querySelectorAll("[data-terminal-state]"));
  const terminalPanels = Array.from(document.querySelectorAll("[data-terminal-panel]"));

  const updateClock = () => {
    if (!clock) return;

    const now = new Date();
    const hours = String(now.getHours()).padStart(2, "0");
    const minutes = String(now.getMinutes()).padStart(2, "0");
    clock.textContent = `${hours}:${minutes}`;
    clock.dateTime = `${hours}:${minutes}`;
  };

  const setActiveWindow = (activeID) => {
    windowLinks.forEach((link) => {
      const active = link.dataset.window === activeID;
      link.classList.toggle("is-active", active);

      if (active) {
        link.setAttribute("aria-current", "location");
        if (mobileWindow) mobileWindow.textContent = `${link.textContent}*`;
      } else {
        link.removeAttribute("aria-current");
      }
    });
  };

  const setTerminalState = (activeState) => {
    const hasPanel = terminalPanels.some(
      (panel) => panel.dataset.terminalPanel === activeState
    );
    if (!hasPanel) return;

    terminalTabs.forEach((tab) => {
      const active = tab.dataset.terminalState === activeState;
      tab.classList.toggle("is-active", active);
      tab.setAttribute("aria-selected", String(active));
      tab.tabIndex = active ? 0 : -1;
    });

    terminalPanels.forEach((panel) => {
      const active = panel.dataset.terminalPanel === activeState;
      panel.classList.toggle("is-active", active);
      panel.setAttribute("aria-hidden", String(!active));
    });
  };

  terminalTabs.forEach((tab, index) => {
    tab.addEventListener("click", () => {
      setTerminalState(tab.dataset.terminalState);
    });

    tab.addEventListener("keydown", (event) => {
      let nextIndex = index;

      if (event.key === "ArrowLeft") {
        nextIndex = (index - 1 + terminalTabs.length) % terminalTabs.length;
      } else if (event.key === "ArrowRight") {
        nextIndex = (index + 1) % terminalTabs.length;
      } else if (event.key === "Home") {
        nextIndex = 0;
      } else if (event.key === "End") {
        nextIndex = terminalTabs.length - 1;
      } else {
        return;
      }

      event.preventDefault();
      const nextTab = terminalTabs[nextIndex];
      nextTab.focus();
      setTerminalState(nextTab.dataset.terminalState);
    });
  });

  const updateActiveWindow = () => {
    if (sections.length === 0) return;

    const readingLine = window.innerHeight * 0.46;
    let activeID = sections[0].id;

    sections.forEach((section) => {
      if (section.getBoundingClientRect().top <= readingLine) activeID = section.id;
    });

    if (window.scrollY + window.innerHeight >= document.documentElement.scrollHeight - 4) {
      activeID = sections[sections.length - 1].id;
    }

    setActiveWindow(activeID);
  };

  let frame = 0;
  const onViewportChange = () => {
    if (frame) return;
    frame = window.requestAnimationFrame(() => {
      frame = 0;
      updateActiveWindow();
    });
  };

  updateClock();
  updateActiveWindow();
  window.setInterval(updateClock, 30_000);
  window.addEventListener("scroll", onViewportChange, { passive: true });
  window.addEventListener("resize", onViewportChange);
})();
