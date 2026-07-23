(() => {
  "use strict";

  const sectionIDs = ["home", "workspace", "preview", "controls", "get"];
  const sections = sectionIDs
    .map((id) => document.getElementById(id))
    .filter((section) => section !== null);
  const windowLinks = Array.from(document.querySelectorAll("[data-window]"));
  const mobileWindow = document.getElementById("mobile-window");
  const clock = document.getElementById("clock");

  windowLinks.forEach((link) => {
    link.dataset.baseLabel = link.textContent.replace(/\*$/, "");
  });

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
      const baseLabel = link.dataset.baseLabel;
      link.classList.toggle("is-active", active);
      link.textContent = `${baseLabel}${active ? "*" : ""}`;

      if (active) {
        link.setAttribute("aria-current", "location");
        if (mobileWindow) mobileWindow.textContent = `${baseLabel}*`;
      } else {
        link.removeAttribute("aria-current");
      }
    });
  };

  const setupPanelTabs = ({
    tabSelector,
    panelSelector,
    tabStateKey,
    panelStateKey,
    onChange,
  }) => {
    const tabs = Array.from(document.querySelectorAll(tabSelector));
    const panels = Array.from(document.querySelectorAll(panelSelector));
    if (tabs.length === 0 || panels.length === 0) return;

    const setState = (activeState) => {
      if (!panels.some((panel) => panel.dataset[panelStateKey] === activeState)) return;

      tabs.forEach((tab) => {
        const active = tab.dataset[tabStateKey] === activeState;
        tab.classList.toggle("is-active", active);
        tab.setAttribute("aria-selected", String(active));
        tab.tabIndex = active ? 0 : -1;
      });

      panels.forEach((panel) => {
        const active = panel.dataset[panelStateKey] === activeState;
        panel.classList.toggle("is-active", active);
        panel.setAttribute("aria-hidden", String(!active));
        panel.inert = !active;
      });

      if (onChange) onChange(activeState);
    };

    tabs.forEach((tab, index) => {
      tab.addEventListener("click", () => setState(tab.dataset[tabStateKey]));
      tab.addEventListener("keydown", (event) => {
        let nextIndex = index;

        if (event.key === "ArrowLeft") {
          nextIndex = (index - 1 + tabs.length) % tabs.length;
        } else if (event.key === "ArrowRight") {
          nextIndex = (index + 1) % tabs.length;
        } else if (event.key === "Home") {
          nextIndex = 0;
        } else if (event.key === "End") {
          nextIndex = tabs.length - 1;
        } else {
          return;
        }

        event.preventDefault();
        const nextTab = tabs[nextIndex];
        nextTab.focus();
        setState(nextTab.dataset[tabStateKey]);
      });
    });

    const selectedTab = tabs.find((tab) => tab.getAttribute("aria-selected") === "true");
    setState((selectedTab ?? tabs[0]).dataset[tabStateKey]);
  };

  setupPanelTabs({
    tabSelector: "[data-workspace-state]",
    panelSelector: "[data-workspace-panel]",
    tabStateKey: "workspaceState",
    panelStateKey: "workspacePanel",
  });

  setupPanelTabs({
    tabSelector: "[data-controls-state]",
    panelSelector: "[data-controls-panel]",
    tabStateKey: "controlsState",
    panelStateKey: "controlsPanel",
  });

  const revealTargets = Array.from(document.querySelectorAll("[data-reveal]"));
  if ("IntersectionObserver" in window) {
    const revealObserver = new IntersectionObserver(
      (entries, observer) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          entry.target.classList.add("is-visible");
          observer.unobserve(entry.target);
        });
      },
      { threshold: 0.12 },
    );
    revealTargets.forEach((target) => revealObserver.observe(target));
  } else {
    revealTargets.forEach((target) => target.classList.add("is-visible"));
  }

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

  const alignInitialHash = () => {
    const targetID = window.location.hash.slice(1);
    if (!sectionIDs.includes(targetID)) return;

    const target = document.getElementById(targetID);
    if (!target) return;

    const root = document.documentElement;
    const previousScrollBehavior = root.style.scrollBehavior;
    const headerHeight = document.querySelector(".site-header")?.getBoundingClientRect().height ?? 0;
    const targetTop = target.getBoundingClientRect().top + window.scrollY - headerHeight - 8;
    root.style.scrollBehavior = "auto";
    window.scrollTo({ top: targetTop });
    root.style.scrollBehavior = previousScrollBehavior;
    updateActiveWindow();
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
  window.addEventListener("load", () => window.requestAnimationFrame(alignInitialHash));
  window.addEventListener("scroll", onViewportChange, { passive: true });
  window.addEventListener("resize", onViewportChange);

  if (document.fonts?.ready) {
    document.fonts.ready.then(() => window.requestAnimationFrame(alignInitialHash));
  }
})();
