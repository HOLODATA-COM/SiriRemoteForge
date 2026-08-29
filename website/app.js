(() => {
  "use strict";

  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const gsapReady = typeof window.gsap !== "undefined";
  const loopRoots = [...document.querySelectorAll("[data-loop-root]")];

  function nativeVideoCanPlay(video) {
    const voiceShowcase = video.closest("[data-voice-showcase]");
    return !voiceShowcase || voiceShowcase.dataset.voiceMode !== "external";
  }

  function prepareVideos() {
    const videos = [...document.querySelectorAll("[data-native-loop]")];
    for (const video of videos) {
      video.muted = true;
      video.loop = true;
      video.playsInline = true;
      if (reducedMotion) {
        video.pause();
        continue;
      }
    }

    if (reducedMotion || !("IntersectionObserver" in window)) {
      for (const video of videos) {
        if (!reducedMotion && nativeVideoCanPlay(video)) video.play().catch(() => {});
      }
      return;
    }

    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        const video = entry.target;
        if (entry.isIntersecting && nativeVideoCanPlay(video)) video.play().catch(() => {});
        else video.pause();
      }
    }, { rootMargin: "180px 0px", threshold: 0.01 });

    videos.forEach((video) => observer.observe(video));
  }

  function addLoop(root, animation) {
    if (!root || !animation) return animation;
    if (!root.__hyperVibeLoops) root.__hyperVibeLoops = [];
    root.__hyperVibeLoops.push(animation);
    animation.pause();
    return animation;
  }

  function observeLoops() {
    if (reducedMotion || !gsapReady) return;
    if (!("IntersectionObserver" in window)) {
      loopRoots.forEach((root) => root.__hyperVibeLoops?.forEach((animation) => animation.play()));
      return;
    }

    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        entry.target.__hyperVibeVisible = entry.isIntersecting;
        for (const animation of entry.target.__hyperVibeLoops ?? []) {
          if (entry.isIntersecting) animation.play();
          else animation.pause();
        }
      }
    }, { rootMargin: "140px 0px", threshold: 0.04 });

    loopRoots.forEach((root) => observer.observe(root));
  }

  function setupHero() {
    const signals = [...document.querySelectorAll("[data-hero-signal]")];
    const root = document.querySelector(".hero-product");
    if (!signals.length || !root || !gsapReady || reducedMotion) return;

    const setSignal = (index) => {
      signals.forEach((signal, signalIndex) => signal.classList.toggle("is-active", signalIndex === index));
    };

    const signalLoop = window.gsap.timeline({ repeat: -1 });
    signals.forEach((_, index) => {
      signalLoop.call(() => setSignal(index));
      signalLoop.to({}, { duration: 2.35 });
    });
    addLoop(root, signalLoop);

    const productFloat = window.gsap.timeline({ repeat: -1, yoyo: true });
    productFloat.to(".hero-widget", { y: -5, duration: 2.8, ease: "sine.inOut" });
    addLoop(root, productFloat);
  }

  function setupWorkflows() {
    const root = document.querySelector("[data-workflow-system]");
    if (!root) return;

    const buttons = [...root.querySelectorAll("[data-workflow-button]")];
    const panels = [...root.querySelectorAll("[data-workflow-panel]")];
    const names = buttons.map((button) => button.dataset.workflowButton);
    let activeName = names[0];
    let timeline = null;
    let resumeTimer = null;

    const setStep = (panel, index) => {
      [...panel.querySelectorAll(".workflow-steps li")].forEach((step, stepIndex) => {
        step.classList.toggle("is-active", stepIndex === index);
      });
    };

    const showWorkflow = (name, animate = true) => {
      if (!names.includes(name)) return;
      activeName = name;
      const next = panels.find((panel) => panel.dataset.workflowPanel === name);
      panels.forEach((panel) => {
        const selected = panel === next;
        panel.classList.toggle("is-active", selected);
        panel.hidden = !selected;
      });
      buttons.forEach((button) => {
        const selected = button.dataset.workflowButton === name;
        button.classList.toggle("is-active", selected);
        button.setAttribute("aria-selected", String(selected));
      });
      if (!next) return;
      setStep(next, 0);

      if (!animate || !gsapReady || reducedMotion || root.__hyperVibeVisible === false) return;
      const targets = [
        next.querySelector(".workflow-story"),
        next.querySelector(".workflow-steps"),
        next.querySelector("footer")
      ].filter(Boolean);
      window.gsap.killTweensOf(targets);
      window.gsap.fromTo(targets,
        { y: 8, autoAlpha: .4 },
        { y: 0, autoAlpha: 1, duration: .24, stagger: .025, ease: "power2.out", overwrite: true });
    };

    showWorkflow(activeName, false);

    buttons.forEach((button) => button.addEventListener("click", () => {
      window.clearTimeout(resumeTimer);
      timeline?.pause();
      showWorkflow(button.dataset.workflowButton, true);
      if (!timeline || reducedMotion) return;
      resumeTimer = window.setTimeout(() => {
        timeline.restart();
        if (root.__hyperVibeVisible === false) timeline.pause();
      }, 10000);
    }));

    if (!gsapReady || reducedMotion) return;
    timeline = window.gsap.timeline({ repeat: -1 });
    names.forEach((name) => {
      timeline.addLabel(`workflow-${name}`)
        .call(() => showWorkflow(name, true));
      const panel = panels.find((candidate) => candidate.dataset.workflowPanel === name);
      const steps = panel ? [...panel.querySelectorAll(".workflow-steps li")] : [];
      steps.forEach((_, index) => {
        timeline.call(() => setStep(panel, index)).to({}, { duration: .76 });
      });
      timeline.to({}, { duration: .62 });
    });
    addLoop(root, timeline);
  }

  function setupInputAtlas() {
    const root = document.querySelector("[data-input-atlas]");
    if (!root) return;
    const keys = [...root.querySelectorAll("[data-input-key]")];
    const gestures = [...root.querySelectorAll(".gesture-spectrum > span")];
    const orbit = root.querySelector(".atlas-orbit");
    if (!keys.length || !gestures.length) return;

    const setActive = (index) => {
      keys.forEach((key, keyIndex) => key.classList.toggle("is-active", keyIndex === index));
      gestures.forEach((gesture, gestureIndex) => gesture.classList.toggle("is-active", gestureIndex === index % gestures.length));
    };
    setActive(0);

    if (!gsapReady || reducedMotion) return;
    const keyLoop = window.gsap.timeline({ repeat: -1 });
    keys.forEach((_, index) => {
      keyLoop.call(() => setActive(index)).to({}, { duration: .66 });
    });
    addLoop(root, keyLoop);

    if (orbit) {
      const orbitLoop = window.gsap.timeline({ repeat: -1 });
      orbitLoop.to(orbit, { rotation: 360, duration: keys.length * .66, ease: "none" });
      addLoop(root, orbitLoop);
    }
  }

  function setupResolverLab() {
    const root = document.querySelector("[data-resolver-lab]");
    if (!root) return;
    const buttons = [...root.querySelectorAll("[data-resolver-case]")];
    const rows = [...root.querySelectorAll("[data-resolver-step]")];
    const context = root.querySelector("[data-resolver-context]");
    const action = root.querySelector("[data-resolver-action]");
    const code = root.querySelector("[data-resolver-code]");
    const cases = buttons.map((button) => button.dataset.resolverCase);
    const presentations = {
      browser: {
        context: "Browser · Navigate · Back",
        match: 0,
        paths: ["browser.Navigate.button.menu", "Navigate.button.menu", "browser.button.menu", "global.button.menu"],
        action: "Browser Back",
        code: "⌘ ["
      },
      music: {
        context: "Music · Browse · Ring",
        match: 0,
        paths: ["music.Browse.circularScroll", "Browse.circularScroll", "music.circularScroll", "global.circularScroll"],
        action: "Horizontal Scroll",
        code: "SCROLL X"
      },
      spaces: {
        context: "Any App · Spaces · Left",
        match: 1,
        paths: ["currentApp.Spaces.ring.left", "Spaces.ring.left", "currentApp.ring.left", "global.ring.left"],
        action: "Previous Space",
        code: "SPACE ←"
      },
      fallback: {
        context: "Other App · Base · Play",
        match: 3,
        paths: ["other.Base.button.playPause", "Base.button.playPause", "other.button.playPause", "global.button.playPause"],
        action: "Play / Pause",
        code: "MEDIA"
      }
    };
    let timeline = null;
    let resumeTimer = null;

    const setCase = (name, animate = true) => {
      const value = presentations[name];
      if (!value) return;
      buttons.forEach((button) => button.classList.toggle("is-active", button.dataset.resolverCase === name));
      rows.forEach((row, index) => {
        row.classList.toggle("is-active", index === value.match);
        const path = row.querySelector("div em");
        const status = row.querySelector(":scope > i");
        if (path) path.textContent = value.paths[index];
        if (status) status.textContent = index === value.match ? "MATCH" : index < value.match ? "MISS" : "—";
      });
      if (context) context.textContent = value.context;
      if (action) action.textContent = value.action;
      if (code) code.textContent = value.code;

      if (!animate || !gsapReady || reducedMotion || root.__hyperVibeVisible === false) return;
      const activeRow = rows[value.match];
      const output = root.querySelector(".resolver-console > footer");
      window.gsap.killTweensOf([activeRow, output]);
      window.gsap.fromTo(activeRow, { x: 7 }, { x: 0, duration: .22, ease: "power2.out", overwrite: true });
      window.gsap.fromTo(output, { autoAlpha: .55 }, { autoAlpha: 1, duration: .24, ease: "power1.out", overwrite: true });
    };

    setCase(cases[0], false);
    buttons.forEach((button) => button.addEventListener("click", () => {
      window.clearTimeout(resumeTimer);
      timeline?.pause();
      setCase(button.dataset.resolverCase, true);
      if (!timeline || reducedMotion) return;
      resumeTimer = window.setTimeout(() => {
        timeline.restart();
        if (root.__hyperVibeVisible === false) timeline.pause();
      }, 9000);
    }));

    if (!gsapReady || reducedMotion) return;
    timeline = window.gsap.timeline({ repeat: -1 });
    cases.forEach((name) => {
      timeline.call(() => setCase(name, true)).to({}, { duration: 2.55 });
    });
    addLoop(root, timeline);
  }

  function setupAgentFlow() {
    const root = document.querySelector(".agent-config-flow");
    const steps = root ? [...root.querySelectorAll("[data-agent-step]")] : [];
    if (!root || !steps.length) return;
    const setStep = (index) => steps.forEach((step, stepIndex) => step.classList.toggle("is-active", stepIndex === index));
    setStep(0);
    if (!gsapReady || reducedMotion) return;
    const timeline = window.gsap.timeline({ repeat: -1 });
    steps.forEach((_, index) => timeline.call(() => setStep(index)).to({}, { duration: .82 }));
    timeline.to({}, { duration: .55 });
    addLoop(root, timeline);
  }

  function setupControlLab() {
    const lab = document.querySelector(".control-lab");
    if (!lab) return;

    const buttons = [...lab.querySelectorAll("[data-control-button]")];
    const label = lab.querySelector("[data-control-label]");
    const primary = lab.querySelector("[data-monitor-primary]");
    const secondary = lab.querySelector("[data-monitor-secondary]");
    const modes = ["pointer", "ring", "drag"];
    const labels = {
      pointer: ["POINTER · XY", "FINGER VELOCITY", "POINTER GAIN"],
      ring: ["RING · ROTATION", "ROTATION VELOCITY", "SCROLL GAIN"],
      drag: ["HOLD · STICKY DRAG", "0.18 s VISUAL LEAD", "0.50 s DRAG"]
    };

    let currentMode = "pointer";
    let modeAnimation = null;
    let automaticTimer = null;
    let resumeTimer = null;

    const killModeAnimation = () => {
      if (modeAnimation) modeAnimation.kill();
      modeAnimation = null;
      window.gsap?.set([
        ".remote-touch", ".pointer-trace i", ".pointer-trace b", ".pointer-trace span",
        ".remote-ring", ".scroll-trace", ".remote-press", ".drag-trace i"
      ], { clearProps: "transform" });
    };

    const createModeAnimation = (mode) => {
      if (!gsapReady || reducedMotion) return null;
      const gsap = window.gsap;

      if (mode === "pointer") {
        const tl = gsap.timeline({ repeat: -1, defaults: { ease: "power2.inOut" } });
        tl.set([".remote-touch", ".pointer-trace i", ".pointer-trace b", ".pointer-trace span"], { x: 0, y: 0 })
          .to(".remote-touch", { x: 42, y: -26, duration: .78 })
          .to([".pointer-trace i", ".pointer-trace b", ".pointer-trace span"], { x: 235, y: -170, duration: .78 }, "<")
          .to(".remote-touch", { x: -32, y: 24, duration: .64 })
          .to([".pointer-trace i", ".pointer-trace b", ".pointer-trace span"], { x: 78, y: -62, duration: .64 }, "<")
          .to(".remote-touch", { x: 30, y: 40, duration: .58 })
          .to([".pointer-trace i", ".pointer-trace b", ".pointer-trace span"], { x: 320, y: -30, duration: .58 }, "<")
          .to(".remote-touch", { x: 0, y: 0, duration: .72 })
          .to([".pointer-trace i", ".pointer-trace b", ".pointer-trace span"], { x: 0, y: 0, duration: .72 }, "<")
          .to({}, { duration: .35 });
        return tl;
      }

      if (mode === "ring") {
        const tl = gsap.timeline({ repeat: -1 });
        tl.set(".remote-ring", { rotation: 0 })
          .set(".scroll-trace", { y: 0 })
          .to(".remote-ring", { rotation: 360, duration: 2.65, ease: "none" })
          .to(".scroll-trace", { y: -150, duration: 2.65, ease: "power1.inOut" }, "<")
          .to(".remote-ring", { rotation: 0, duration: .01 })
          .to(".scroll-trace", { y: 0, duration: .24, ease: "power2.out" }, "<")
          .to({}, { duration: .32 });
        return tl;
      }

      const tl = gsap.timeline({ repeat: -1, defaults: { ease: "power3.out" } });
      tl.set(".remote-press", { scale: .4, autoAlpha: 0 })
        .set(".drag-trace i", { x: 0, y: 0, rotation: 0 })
        .to(".remote-press", { scale: 1, autoAlpha: 1, duration: .24 })
        .to(".remote-press", { scale: 1.55, autoAlpha: 0, duration: .34 })
        .to(".drag-trace i", { x: 155, y: 105, rotation: 2, duration: 1.05, ease: "power2.inOut" }, "<.12")
        .to({}, { duration: .48 })
        .to(".drag-trace i", { x: 0, y: 0, rotation: 0, duration: .72, ease: "power3.inOut" })
        .to({}, { duration: .36 });
      return tl;
    };

    const setMode = (mode) => {
      if (!modes.includes(mode)) return;
      currentMode = mode;
      lab.dataset.controlMode = mode;
      buttons.forEach((button) => button.classList.toggle("is-active", button.dataset.controlButton === mode));
      const copy = labels[mode];
      if (label) label.textContent = copy[0];
      if (primary) primary.textContent = copy[1];
      if (secondary) secondary.textContent = copy[2];

      if (!gsapReady || reducedMotion) return;
      killModeAnimation();
      modeAnimation = createModeAnimation(mode);
      if (lab.__hyperVibeVisible !== false) modeAnimation?.play();
    };

    const startAutomaticCycle = () => {
      window.clearInterval(automaticTimer);
      automaticTimer = window.setInterval(() => {
        const nextIndex = (modes.indexOf(currentMode) + 1) % modes.length;
        setMode(modes[nextIndex]);
      }, 5200);
    };

    buttons.forEach((button) => button.addEventListener("click", () => {
      setMode(button.dataset.controlButton);
      window.clearInterval(automaticTimer);
      window.clearTimeout(resumeTimer);
      resumeTimer = window.setTimeout(startAutomaticCycle, 12000);
    }));

    setMode("pointer");
    if (!reducedMotion) startAutomaticCycle();

    if (gsapReady && !reducedMotion && "IntersectionObserver" in window) {
      const observer = new IntersectionObserver(([entry]) => {
        lab.__hyperVibeVisible = entry.isIntersecting;
        if (entry.isIntersecting) modeAnimation?.play();
        else modeAnimation?.pause();
      }, { rootMargin: "120px 0px", threshold: .04 });
      observer.observe(lab);
    }
  }

  function setupCurveLoops() {
    if (!gsapReady || reducedMotion) return;
    const specs = [...document.querySelectorAll(".curve-spec")];
    specs.forEach((spec, index) => {
      const runner = spec.querySelector(".curve-runner");
      const root = spec.closest("[data-loop-root]");
      if (!runner || !root) return;

      const points = index === 0
        ? [[0, 0], [78, -18], [162, -70], [245, -82], [324, -82]]
        : [[0, 0], [78, -21], [160, -62], [242, -76], [324, -76]];
      const tl = window.gsap.timeline({ repeat: -1, defaults: { duration: .62, ease: "power1.inOut" } });
      tl.set(runner, { x: points[0][0], y: points[0][1] });
      points.slice(1).forEach(([x, y]) => tl.to(runner, { x, y }));
      tl.to({}, { duration: .35 }).to(runner, { x: 0, y: 0, duration: .28, ease: "power2.out" });
      addLoop(root, tl);
    });
  }

  function setupVoicePipeline() {
    const root = document.querySelector("[data-voice-showcase]");
    const system = document.querySelector("[data-voice-mode-system]");
    const loopRoot = root?.closest("[data-loop-root]") ?? root;
    const stages = [...document.querySelectorAll("[data-voice-stage]")];
    const modeButtons = [...document.querySelectorAll("button[data-voice-mode]")];
    const modeTitle = document.querySelector("[data-voice-mode-title]");
    const modeCopy = document.querySelector("[data-voice-mode-copy]");
    const modeOverlay = document.querySelector("[data-voice-mode-overlay]");
    const filmState = document.querySelector("[data-voice-film-state]");
    const filmCommand = document.querySelector("[data-voice-film-command]");
    const video = root?.querySelector("video");
    if (!root || !system || !loopRoot || !stages.length || !modeButtons.length) return;

    const modes = ["external", "final", "streaming"];
    const presentation = {
      external: {
        title: "External · 现有动作",
        copy: "侧键继续执行 JSON 中原本的快捷键或外部语音动作。",
        overlay: "VOICE CAPSULE OFF",
        film: "EXTERNAL · NO VOICE CAPSULE",
        command: "SIDE ACTION PASSTHROUGH"
      },
      final: {
        title: "Final · 最终润色",
        copy: "完整转写后快速整理表达，再交付到当前输入框。",
        overlay: "VOICE CAPSULE ON",
        film: "FINAL VOICE PIPELINE",
        command: "HOLD · SPEAK · POLISH"
      },
      streaming: {
        title: "Live · 实时流式",
        copy: "第一段文字在说话时抵达，更在乎连续性与即时反馈。",
        overlay: "VOICE CAPSULE ON",
        film: "LIVE VOICE PIPELINE",
        command: "HOLD · SPEAK · STREAM"
      }
    };

    let timeline = null;
    let resumeTimer = null;

    const setStage = (activeIndex) => {
      stages.forEach((stage, index) => stage.classList.toggle("is-active", index === activeIndex));
    };

    const setMode = (mode, animate = true, restartVideo = true) => {
      if (!modes.includes(mode)) return;
      const content = presentation[mode];
      root.dataset.voiceMode = mode;
      system.dataset.activeMode = mode;
      modeButtons.forEach((button) => {
        const selected = button.dataset.voiceMode === mode;
        button.classList.toggle("is-active", selected);
        button.setAttribute("aria-pressed", String(selected));
      });
      if (modeTitle) modeTitle.textContent = content.title;
      if (modeCopy) modeCopy.textContent = content.copy;
      if (modeOverlay) modeOverlay.textContent = content.overlay;
      if (filmState) filmState.textContent = content.film;
      if (filmCommand) filmCommand.textContent = content.command;

      if (video) {
        if (mode === "external" || reducedMotion) {
          video.pause();
        } else {
          if (restartVideo) {
            try { video.currentTime = 0; } catch (_) {}
          }
          if (loopRoot.__hyperVibeVisible !== false) video.play().catch(() => {});
        }
      }

      if (!animate || !gsapReady || reducedMotion) return;
      const active = modeButtons.find((button) => button.dataset.voiceMode === mode);
      const icon = active?.querySelector("svg");
      const labels = active ? [active.querySelector("b"), active.querySelector("em")].filter(Boolean) : [];
      const readout = system.querySelector(".voice-mode-readout");
      window.gsap.killTweensOf([icon, ...labels, readout]);
      if (icon) {
        window.gsap.fromTo(icon,
          { rotationY: -78, autoAlpha: .28, transformPerspective: 320 },
          { rotationY: 0, autoAlpha: 1, duration: .24, ease: "power2.out", overwrite: true });
      }
      if (labels.length) {
        window.gsap.fromTo(labels,
          { y: 5, autoAlpha: .38 },
          { y: 0, autoAlpha: 1, duration: .22, stagger: .025, ease: "power2.out", overwrite: true });
      }
      if (readout) {
        window.gsap.fromTo(readout,
          { y: 4, autoAlpha: .58 },
          { y: 0, autoAlpha: 1, duration: .24, ease: "power2.out", overwrite: true });
      }
    };

    setMode("final", false, false);
    setStage(0);

    modeButtons.forEach((button) => button.addEventListener("click", () => {
      const mode = button.dataset.voiceMode;
      window.clearTimeout(resumeTimer);
      timeline?.pause();
      setMode(mode, true, true);
      setStage(mode === "external" ? -1 : 0);
      if (!timeline || reducedMotion) return;
      resumeTimer = window.setTimeout(() => {
        timeline.restart();
        if (loopRoot.__hyperVibeVisible === false) timeline.pause();
      }, 9000);
    }));

    if (!gsapReady || reducedMotion) return;

    // One authored loop owns both global-mode selection and native-pipeline stages. External gets
    // a truthful empty surface; Final and Live restart the real native film at their mode boundary.
    timeline = window.gsap.timeline({ repeat: -1 });
    timeline.addLabel("external")
      .call(() => { setMode("external"); setStage(-1); })
      .to({}, { duration: 2.15 })
      .addLabel("final")
      .call(() => { setMode("final"); setStage(0); })
      .to({}, { duration: .55 })
      .call(() => setStage(1))
      .to({}, { duration: 1.85 })
      .call(() => setStage(2))
      .to({}, { duration: 2.96 })
      .addLabel("streaming")
      .call(() => { setMode("streaming"); setStage(0); })
      .to({}, { duration: .55 })
      .call(() => setStage(1))
      .to({}, { duration: 1.85 })
      .call(() => setStage(2))
      .to({}, { duration: 2.96 });
    addLoop(loopRoot, timeline);
  }

  prepareVideos();
  setupHero();
  setupWorkflows();
  setupInputAtlas();
  setupResolverLab();
  setupAgentFlow();
  setupControlLab();
  setupCurveLoops();
  setupVoicePipeline();
  observeLoops();
})();
