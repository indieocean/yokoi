// Yokoi site: scroll reveals, tour tabs, typed terminal, background pixels, latest release lookup.
(() => {
  const doc = document.documentElement;
  doc.classList.add("js");
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Copy the install command
  document.querySelectorAll("[data-copy]").forEach((btn) => {
    let timer;
    btn.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(btn.dataset.copy);
      } catch {
        getSelection().selectAllChildren(btn.previousElementSibling);
        return;
      }
      btn.textContent = "Copied";
      btn.classList.add("done");
      btn.setAttribute("aria-label", "Copied");
      clearTimeout(timer);
      timer = setTimeout(() => {
        btn.textContent = "Copy";
        btn.classList.remove("done");
        btn.setAttribute("aria-label", "Copy the install command");
      }, 1800);
    });
  });

  // Nav border once scrolled
  const nav = document.querySelector(".nav");
  const onScroll = () => nav.classList.toggle("scrolled", scrollY > 8);
  addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  // Scroll reveal
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
  }, { rootMargin: "0px 0px -8% 0px" });
  document.querySelectorAll(".reveal").forEach((el, i) => {
    el.style.transitionDelay = `${Math.min(i % 6, 5) * 50}ms`;
    io.observe(el);
  });

  // Card spotlight follows the pointer
  document.querySelectorAll(".card").forEach((card) => {
    card.addEventListener("pointermove", (e) => {
      const r = card.getBoundingClientRect();
      card.style.setProperty("--mx", `${e.clientX - r.left}px`);
      card.style.setProperty("--my", `${e.clientY - r.top}px`);
    });
  });

  // Tour tabs
  const tabs = [...document.querySelectorAll(".seg button")];
  const img = document.getElementById("tour-img");
  const cap = document.getElementById("tour-cap");
  const select = (btn) => {
    tabs.forEach((t) => t.setAttribute("aria-selected", String(t === btn)));
    img.classList.add("fading");
    const next = new Image();
    next.src = `img/${btn.dataset.shot}.webp`;
    next.decode().catch(() => {}).finally(() => {
      img.src = next.src;
      img.alt = btn.dataset.cap;
      cap.textContent = btn.dataset.cap;
      img.classList.remove("fading");
    });
  };
  tabs.forEach((btn, i) => {
    btn.addEventListener("click", () => select(btn));
    btn.addEventListener("keydown", (e) => {
      const d = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0;
      if (!d) return;
      const t = tabs[(i + d + tabs.length) % tabs.length];
      t.focus();
      select(t);
    });
  });

  // Typed terminal targets
  const typer = document.querySelector("[data-typer]");
  const words = ["node_modules", "DerivedData", "target/", "~/Library/Caches", ".gradle", "docker images", "Unity Library/", "brew · cargo · pip"];
  if (typer && !reduceMotion) {
    let w = 0, c = 0, deleting = false;
    typer.textContent = "";
    const tick = () => {
      const word = words[w];
      c += deleting ? -1 : 1;
      typer.textContent = word.slice(0, c);
      let delay = deleting ? 35 : 70;
      if (!deleting && c === word.length) { deleting = true; delay = 1500; }
      else if (deleting && c === 0) { deleting = false; w = (w + 1) % words.length; delay = 300; }
      setTimeout(tick, delay);
    };
    setTimeout(tick, 900);
  }

  // Drifting violet/cyan pixels, like the header art
  const canvas = document.querySelector(".bg-particles");
  if (canvas && !reduceMotion) {
    const ctx = canvas.getContext("2d");
    const colors = ["124,92,255", "34,211,238", "167,139,250"];
    let w, h, dpr, dots = [];
    const resize = () => {
      dpr = Math.min(devicePixelRatio || 1, 2);
      w = canvas.width = innerWidth * dpr;
      h = canvas.height = innerHeight * dpr;
      const n = Math.round(Math.min(70, (innerWidth * innerHeight) / 22000));
      dots = Array.from({ length: n }, () => ({
        x: Math.random() * w, y: Math.random() * h,
        s: (Math.random() * 2.2 + 1.2) * dpr,
        v: (Math.random() * 0.12 + 0.03) * dpr,
        a: Math.random() * 0.5 + 0.15,
        p: Math.random() * Math.PI * 2,
        c: colors[(Math.random() * colors.length) | 0],
      }));
    };
    const draw = (t) => {
      ctx.clearRect(0, 0, w, h);
      for (const d of dots) {
        d.y -= d.v;
        if (d.y < -10) { d.y = h + 10; d.x = Math.random() * w; }
        const a = d.a * (0.6 + 0.4 * Math.sin(t / 900 + d.p));
        ctx.fillStyle = `rgba(${d.c},${a})`;
        ctx.fillRect(d.x, d.y, d.s, d.s);
      }
      requestAnimationFrame(draw);
    };
    resize();
    addEventListener("resize", resize);
    requestAnimationFrame(draw);
  }

  // Point download buttons at the latest .dmg and show its version (falls back to the static links)
  fetch("https://api.github.com/repos/indieocean/yokoi/releases/latest", { headers: { Accept: "application/vnd.github+json" } })
    .then((r) => (r.ok ? r.json() : Promise.reject()))
    .then((rel) => {
      const tag = String(rel.tag_name || "").trim();
      if (/^v?\d+(\.\d+){0,3}$/.test(tag)) {
        const v = tag.startsWith("v") ? tag : `v${tag}`;
        document.querySelectorAll("[data-version]").forEach((el) => (el.textContent = v));
      }
      const dmg = (rel.assets || []).find((a) => /\.dmg$/i.test(a.name));
      const url = dmg && String(dmg.browser_download_url);
      if (url && url.startsWith("https://github.com/indieocean/yokoi/releases/download/")) {
        document.querySelectorAll("[data-download]").forEach((a) => (a.href = url));
      }
    })
    .catch(() => {});
})();
