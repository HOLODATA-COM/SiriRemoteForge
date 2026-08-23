(() => {
  "use strict";

  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const gsapReady = typeof window.gsap !== "undefined";
  const loopRoots = [...document.querySelectorAll("[data-loop-root]")];

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
        if (!reducedMotion) video.play().catch(() => {});
      }
      return;
    }

    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        const video = entry.target;
        if (entry.isIntersecting) video.play().catch(() => {});
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

  prepareVideos();
  setupHero();
  setupControlLab();
  setupCurveLoops();
  observeLoops();
})();
